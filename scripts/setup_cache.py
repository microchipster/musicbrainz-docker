#!/usr/bin/env python3

import argparse
import hashlib
import json
import os
import pathlib
import re
import subprocess
import time
from collections import defaultdict
from typing import Iterable


IMPORT_PATCH_SPECS = (
    ("mbdump-derived.tar.bz2", "annotation"),
    ("mbdump.tar.bz2", "artist_credit"),
    ("mbdump.tar.bz2", "label"),
    ("mbdump.tar.bz2", "recording"),
    ("mbdump.tar.bz2", "l_recording_work"),
    ("mbdump.tar.bz2", "release_group"),
    ("mbdump.tar.bz2", "release_label"),
    ("mbdump.tar.bz2", "track"),
    ("mbdump.tar.bz2", "url"),
)

PATCH_SOURCE_MANIFEST_VERSION = 1


def status(message: str) -> None:
    print(f"[{time.strftime('%Y-%m-%d %H:%M:%S')}] {message}", flush=True)


def md5(path: pathlib.Path) -> str:
    digest = hashlib.md5()
    with path.open("rb") as fh:
        for chunk in iter(lambda: fh.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def patch_manifest_path(target_path: pathlib.Path) -> pathlib.Path:
    return target_path.with_name(f".{target_path.name}.manifest.json")


def archive_identity(archive: pathlib.Path) -> dict[str, int | str]:
    stat = archive.stat()
    return {
        "archive": archive.name,
        "archive_size": stat.st_size,
        "archive_mtime_ns": stat.st_mtime_ns,
    }


def write_patch_manifest(
    target_path: pathlib.Path,
    archive: pathlib.Path,
    member_name: str,
    checksum: str,
) -> None:
    manifest = {
        "version": PATCH_SOURCE_MANIFEST_VERSION,
        **archive_identity(archive),
        "member": member_name,
        "target_size": target_path.stat().st_size,
        "target_md5": checksum,
    }
    patch_manifest_path(target_path).write_text(
        json.dumps(manifest, sort_keys=True, indent=2) + "\n",
        encoding="utf-8",
    )


def patch_source_current(archive: pathlib.Path, member_name: str, target_path: pathlib.Path) -> bool:
    manifest_path = patch_manifest_path(target_path)

    if not target_path.is_file() or target_path.stat().st_size <= 0 or not manifest_path.is_file():
        return False

    try:
        manifest = json.loads(manifest_path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError):
        return False

    if manifest.get("version") != PATCH_SOURCE_MANIFEST_VERSION:
        return False

    for key, value in archive_identity(archive).items():
        if manifest.get(key) != value:
            return False

    if manifest.get("member") != member_name:
        return False
    if manifest.get("target_size") != target_path.stat().st_size:
        return False

    expected_md5 = manifest.get("target_md5")
    return isinstance(expected_md5, str) and md5(target_path) == expected_md5


def extract_tar_member(archive: pathlib.Path, member_name: str, target_path: pathlib.Path) -> str:
    tmp_path = target_path.with_name(f"{target_path.name}.tmp.{os.getpid()}")
    tmp_path.unlink(missing_ok=True)
    digest = hashlib.md5()

    proc = subprocess.Popen(
        ["tar", "-xOf", str(archive), member_name],
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
    )
    assert proc.stdout is not None

    copied = 0
    next_report = 1024 * 1024 * 1024
    try:
        with tmp_path.open("wb") as out:
            while True:
                chunk = proc.stdout.read(1024 * 1024)
                if not chunk:
                    break
                digest.update(chunk)
                out.write(chunk)
                copied += len(chunk)
                if copied >= next_report:
                    status(f"Still extracting {target_path.name}: wrote {copied // (1024 * 1024)} MiB")
                    next_report += 1024 * 1024 * 1024

        stderr = proc.stderr.read().decode("utf-8", errors="replace") if proc.stderr else ""
        status_code = proc.wait()
        if status_code != 0:
            raise RuntimeError(
                f"tar failed extracting {member_name} from {archive.name} with exit {status_code}: {stderr.strip()}"
            )

        os.replace(tmp_path, target_path)
        expected_md5 = digest.hexdigest()
        actual_md5 = md5(target_path)
        if actual_md5 != expected_md5:
            target_path.unlink(missing_ok=True)
            patch_manifest_path(target_path).unlink(missing_ok=True)
            raise RuntimeError(
                f"Extracted patch source {target_path.name} failed read-back verification: "
                f"expected {expected_md5}, got {actual_md5}. "
                "The host did not preserve bytes that were just written; repair the filesystem "
                "and run a memory/hardware test before retrying the import."
            )

        return actual_md5
    except Exception:
        tmp_path.unlink(missing_ok=True)
        if proc.poll() is None:
            proc.kill()
            proc.wait()
        raise


def iter_md5_entries(md5_file: pathlib.Path, suffix: str) -> Iterable[tuple[str, str]]:
    pattern = re.compile(rf"^([0-9a-fA-F]{{32}}) \*(.+\{suffix})$")
    for line in md5_file.read_text(encoding="utf-8").splitlines():
        match = pattern.match(line.strip())
        if match:
            yield match.group(1).lower(), match.group(2)


def prepare_import_patch_sources(args: argparse.Namespace) -> int:
    dbdump_dir = pathlib.Path(args.dbdump_dir)
    source_dir = pathlib.Path(args.source_dir)
    specs_by_archive = defaultdict(list)
    source_dir.mkdir(parents=True, exist_ok=True)

    status(f"Preparing import patch sources in {source_dir}")
    for tmp_path in source_dir.glob("*.tmp.*"):
        status(f"Removing stale temporary patch source {tmp_path.name}")
        tmp_path.unlink(missing_ok=True)

    for archive_name, table in IMPORT_PATCH_SPECS:
        specs_by_archive[archive_name].append(table)

    for archive_name, tables in specs_by_archive.items():
        archive = dbdump_dir / archive_name
        if not archive.is_file():
            for table in tables:
                status(f"Skipping patch source {table}: missing archive {archive_name}")
            continue

        pending = {}
        for table in tables:
            member_name = f"mbdump/{table}"
            target_path = source_dir / table
            if patch_source_current(archive, member_name, target_path):
                status(f"Patch source {table} is current and checksum-verified; skipping extraction")
                continue
            pending[member_name] = table

        if not pending:
            continue

        for member_name, table in pending.items():
            target_path = source_dir / table
            status(f"Extracting patch source {table} from {archive_name}")
            actual_md5 = extract_tar_member(archive, member_name, target_path)
            write_patch_manifest(target_path, archive, member_name, actual_md5)
            status(f"Finished patch source {table}: wrote and verified {target_path.stat().st_size // (1024 * 1024)} MiB")

    status("Finished preparing import patch sources")
    return 0


def repair_solr_cache(args: argparse.Namespace) -> int:
    backup_dir = pathlib.Path(args.backup_dir)
    md5_file = backup_dir / "MD5SUMS"

    if not md5_file.is_file():
        return 0

    for path in backup_dir.iterdir():
        if path.is_file() and (path.name.endswith(".part") or ".tmp." in path.name):
            path.unlink(missing_ok=True)

    for checksum, filename in iter_md5_entries(md5_file, ".tar.zst"):
        path = backup_dir / filename
        if path.is_file() and md5(path) != checksum:
            print(filename)
            path.unlink(missing_ok=True)

    return 0


def verify_solr_cache(args: argparse.Namespace) -> int:
    backup_dir = pathlib.Path(args.backup_dir)
    md5_file = backup_dir / "MD5SUMS"

    if not md5_file.is_file():
        return 1

    entries = list(iter_md5_entries(md5_file, ".tar.zst"))
    if not entries:
        return 1

    for checksum, filename in entries:
        path = backup_dir / filename
        if not path.is_file():
            return 1
        if md5(path) != checksum:
            return 1

    return 0


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser()
    subparsers = parser.add_subparsers(dest="command", required=True)

    prepare = subparsers.add_parser("prepare-import-patch-sources")
    prepare.add_argument("dbdump_dir")
    prepare.add_argument("source_dir")
    prepare.set_defaults(func=prepare_import_patch_sources)

    repair = subparsers.add_parser("repair-solr-cache")
    repair.add_argument("backup_dir")
    repair.set_defaults(func=repair_solr_cache)

    verify = subparsers.add_parser("verify-solr-cache")
    verify.add_argument("backup_dir")
    verify.set_defaults(func=verify_solr_cache)

    return parser


def main() -> int:
    parser = build_parser()
    args = parser.parse_args()
    return args.func(args)


if __name__ == "__main__":
    raise SystemExit(main())
