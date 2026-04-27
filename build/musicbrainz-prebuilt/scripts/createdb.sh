#!/bin/bash

set -e -o pipefail -u

BASE_DOWNLOAD_URL="${MUSICBRAINZ_BASE_FTP_URL:-$MUSICBRAINZ_BASE_DOWNLOAD_URL}"
IMPORT="fullexport"
FETCH_DUMPS=""
WGET_OPTIONS=""
TMP_DIR="${MUSICBRAINZ_IMPORT_TMP_DIR:-/media/dbdump/tmp}"
CACHE_DUMP_DIR="${MUSICBRAINZ_CACHE_DUMP_DIR:-/media/dbdump}"
IMPORT_TMP_DIR="$TMP_DIR/import"
PATCH_SOURCE_DIR="${MUSICBRAINZ_IMPORT_PATCH_SOURCE_DIR:-$CACHE_DUMP_DIR/patch-sources}"
INITDB_PGOPTIONS="${MUSICBRAINZ_INITDB_PGOPTIONS:--c max_parallel_maintenance_workers=0 -c max_parallel_workers_per_gather=0 -c max_parallel_workers=0 -c jit=off}"
VALIDATE_CACHED_DUMPS="${MUSICBRAINZ_VALIDATE_CACHED_DUMPS:-0}"

HELP=$(cat <<EOH
Usage: $0 [-wget-opts <options list>] [-sample] [-fetch] [MUSICBRAINZ_BASE_DOWNLOAD_URL]

Options:
  -fetch      Fetch latest dump from MusicBrainz download server
  -sample     Load sample data instead of full data
  -wget-opts  Pass additional space-separated options list (should be
              a single argument, escape spaces if necessary) to wget

Default MusicBrainz base download URL: $BASE_DOWNLOAD_URL
EOH
)

cleanup_tmp_dir() {
    rm -rf -- "$TMP_DIR"
}

prepare_import_tmp_dir() {
    mkdir -p "$IMPORT_TMP_DIR"
}

ensure_system_schema() {
    PGPASSWORD="$POSTGRES_PASSWORD" \
        psql -v ON_ERROR_STOP=1 \
            -h "$MUSICBRAINZ_POSTGRES_SERVER" \
            -U "$POSTGRES_USER" \
            -d template1 \
            -c 'CREATE SCHEMA IF NOT EXISTS musicbrainz' \
            >/dev/null
}

validate_local_dumps() {
    local checksum_source=$1
    local file
    local checksum_line

    if [[ "$VALIDATE_CACHED_DUMPS" != 1 ]]; then
        return
    fi

    for file in "${DUMP_FILES[@]}"; do
        if [[ -r "$checksum_source/MD5SUMS" ]]; then
            checksum_line=$(grep -F "*$file" "$checksum_source/MD5SUMS" || true)
            if [[ -z "$checksum_line" ]]; then
                echo "$0: Missing checksum for staged dump '$file'"
                exit 70
            fi
            if ! (cd "$CACHE_DUMP_DIR" && printf '%s\n' "$checksum_line" | md5sum -c --status); then
                echo "$0: Staged dump '$file' failed checksum validation"
                exit 70
            fi
        fi

        case "$file" in
            *.bz2)
                bzip2 -t -- "$CACHE_DUMP_DIR/$file"
                ;;
            *.xz)
                xz -t -- "$CACHE_DUMP_DIR/$file"
                ;;
        esac
    done
}

trap cleanup_tmp_dir EXIT

if [ $# -gt 4 ]; then
    echo "$0: too many arguments"
    echo "$HELP"
    exit 1
fi

while [ $# -gt 0 ]; do
    case "$1" in
        -wget-opts )
            shift
            WGET_OPTIONS=$1
            ;;
        -sample )
            IMPORT="sample"
            ;;
        -fetch  )
            FETCH_DUMPS="$1"
            ;;
        -*      )
            echo "$0: unrecognized option '$1'"
            echo "$HELP"
            exit 1
            ;;
        *       )
            BASE_DOWNLOAD_URL="$1"
            ;;
    esac
    shift
done

case "$IMPORT" in
    fullexport  )
        if [[ $MUSICBRAINZ_STANDALONE_SERVER -eq 1 ]]; then
            echo "$0: Only sample data can be loaded in standalone mode"
            echo "$HELP"
            exit 1
        fi
        DUMP_FILES=(
            mbdump.tar.bz2
            mbdump-cdstubs.tar.bz2
            mbdump-cover-art-archive.tar.bz2
            mbdump-event-art-archive.tar.bz2
            mbdump-derived.tar.bz2
            mbdump-stats.tar.bz2
            mbdump-wikidocs.tar.bz2
        );;
    sample      )
        if [[ $MUSICBRAINZ_STANDALONE_SERVER -eq 0 ]]; then
            echo "$0: Only full data can be loaded in mirror mode"
            echo "$HELP"
            exit 1
        fi
        DUMP_FILES=(
            mbdump-sample.tar.xz
        );;
esac

prepare_import_tmp_dir

if [[ $FETCH_DUMPS == "-fetch" ]]; then
    FETCH_OPTIONS=("${IMPORT/fullexport/replica}" --base-download-url "$BASE_DOWNLOAD_URL")
    if [[ -n "$WGET_OPTIONS" ]]; then
        FETCH_OPTIONS+=(--wget-options "$WGET_OPTIONS")
    fi
    MUSICBRAINZ_DB_DUMP_DIR="$CACHE_DUMP_DIR" fetch-dump.sh "${FETCH_OPTIONS[@]}"
fi

for F in "${DUMP_FILES[@]}"; do
    if ! [[ -a "$CACHE_DUMP_DIR/$F" ]]; then
        echo "$0: The dump '$F' is missing"
        exit 1
    fi
done

validate_local_dumps "$CACHE_DUMP_DIR"

echo "found existing dumps"
dockerize -wait "tcp://${MUSICBRAINZ_POSTGRES_SERVER}:5432" -timeout 60s sleep 0
ensure_system_schema

cd "$CACHE_DUMP_DIR"

INITDB_OPTIONS='--echo --import'
if ! carton exec -- /musicbrainz-server/script/database_exists MAINTENANCE; then
    INITDB_OPTIONS="--createdb $INITDB_OPTIONS"
fi
# shellcheck disable=SC2086
carton exec -- env PGOPTIONS="${PGOPTIONS:+$PGOPTIONS }$INITDB_PGOPTIONS" MUSICBRAINZ_IMPORT_PATCH_SOURCE_DIR="$PATCH_SOURCE_DIR" /musicbrainz-server/admin/InitDb.pl \
    $INITDB_OPTIONS -- --skip-editor --tmp-dir "$IMPORT_TMP_DIR" "${DUMP_FILES[@]}"
