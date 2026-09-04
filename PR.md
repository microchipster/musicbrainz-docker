# Make `setup-musicbrainz` rerunnable and harden full bootstrap

## Summary

This change set turns local MusicBrainz bootstrap into a rerunnable host-side workflow that can recover from partial installs, reuse validated dump/search caches, and verify that the web/API/search stack is actually healthy before declaring success.

Compared with `upstream/master`, the branch adds a new `./setup-musicbrainz` entrypoint, hardens the full import path in the prebuilt `musicbrainz` image, keeps persistent state under configurable host data roots by default, and tunes PostgreSQL/SIR/Solr for the heavy bootstrap and search-seeding phases.

## PR Split

The local `master` stack is intentionally split into one commit per proposed PR, all based on `upstream/master` and ordered as follows:

```text
pr/01-postgres-db-name        fix: set default MusicBrainz database name
pr/02-verify-helper           add deployment verification helper
pr/03-cached-imports          harden cached dump imports
pr/04-compose-runtime         tune bootstrap compose runtime
pr/05-search-bootstrap        harden search bootstrap
pr/06-setup-wrapper           add rerunnable setup wrapper
```

Each `pr/*` branch points at the corresponding commit in the stack. `master` contains all six commits in order.

## What Is Different From `master`

### 1. New host-side `./setup-musicbrainz`

`master` documents a mostly manual flow: build images, fetch/import dumps, start services, wire replication, seed search, and verify the site yourself.

This branch adds `setup-musicbrainz`, which now:

- uses the already-checked-out repo and leaves git operations to the user
- sources optional local setup defaults from `local/setup.env`
- writes the local bind-mount override
- validates/reuses the configured dump cache instead of redownloading on every rerun
- reports the exact missing required dump files before any expensive checksum validation
- refuses base dump downloads unless `MUSICBRAINZ_ALLOW_BASE_DOWNLOADS=1`
- refuses Solr backup downloads unless `MUSICBRAINZ_ALLOW_SOLR_DOWNLOADS=1`
- keeps Solr backup verification strict by default, with an explicit `MUSICBRAINZ_ALLOW_PARTIAL_SOLR_BOOTSTRAP=1` escape hatch that creates missing collections without restored data when an operator accepts degraded search bootstrap
- prepares checksum-verified patch-source files for importer-sensitive tables
- repairs bad Docker volume layouts
- leaves git updates to the user and reconciles the already-checked-out source
- refreshes images through `docker compose build` so Compose/Docker cache handles changed build inputs
- starts only the core services needed for bootstrap
- detects whether the database is healthy, missing, empty, or partial
- fails setup immediately when the database phase fails instead of starting the app against an empty database
- performs one expensive DB import attempt by default and preserves the root-cause output on failure
- wires the compose stack so replication token and replication cron are active at runtime
- wires search so Solr is seeded from verified backup archives and then kept current with live indexing
- recreates services when health checks show stale runtime state and only clears derived RabbitMQ/Solr data with `MUSICBRAINZ_REPAIR_DERIVED_DATA=1`
- optionally adds an Ubuntu UFW rule for the published web port when UFW is active
- starts `musicbrainz`
- recreates the web service once if HTTP verification fails after startup
- runs a reusable `./verify-musicbrainz` health gate at the end
- verifies both the homepage and a real `/ws/2` artist lookup

Why:
The old flow was too fragile for long imports. A rerunnable host wrapper was needed so a broken install could be retried safely and a healthy install could be re-entered without destructive steps.

The intended rerun contract is explicit: each invocation should install missing pieces, update changed runtime pieces from the user's current checkout, repair broken derived state, or do any combination of those actions while preserving validated base dump caches, Solr backup caches, and initialized PostgreSQL data unless a step proves those derived runtime assets must be recreated. The wrapper does not mutate git state; users update/rebase/pull the repository separately, then rerun `./setup-musicbrainz` to reconcile the deployed containers with that checkout.

### 2. PostgreSQL now initializes the correct application database

`default/postgres.env` now sets:

```env
POSTGRES_DB=musicbrainz_db
```

Why:
The application expects `musicbrainz_db`, but the stock Postgres image created a default database named after `POSTGRES_USER` (`musicbrainz`) when `POSTGRES_DB` was unset. That mismatch caused setup to talk to the wrong database and made reruns ambiguous.

### 3. Persistent storage uses configurable host data roots

The generated compose override keeps all persistent MusicBrainz state under one data root by default:

```text
${MUSICBRAINZ_DATA_DIR:-${XDG_DATA_HOME:-$HOME/.local/share}/musicbrainz-docker}/dbdump
${MUSICBRAINZ_DATA_DIR:-${XDG_DATA_HOME:-$HOME/.local/share}/musicbrainz-docker}/solrdump
${MUSICBRAINZ_DATA_DIR:-${XDG_DATA_HOME:-$HOME/.local/share}/musicbrainz-docker}/pgdata
${MUSICBRAINZ_DATA_DIR:-${XDG_DATA_HOME:-$HOME/.local/share}/musicbrainz-docker}/mqdata
${MUSICBRAINZ_DATA_DIR:-${XDG_DATA_HOME:-$HOME/.local/share}/musicbrainz-docker}/solrdata
```

For hosts with different storage classes, the same wrapper also supports a generic split:

```text
${MUSICBRAINZ_CACHE_DIR:-$MUSICBRAINZ_DATA_DIR}/dbdump
${MUSICBRAINZ_CACHE_DIR:-$MUSICBRAINZ_DATA_DIR}/solrdump
${MUSICBRAINZ_LIVE_DATA_DIR:-$MUSICBRAINZ_DATA_DIR}/pgdata
${MUSICBRAINZ_LIVE_DATA_DIR:-$MUSICBRAINZ_DATA_DIR}/mqdata
${MUSICBRAINZ_LIVE_DATA_DIR:-$MUSICBRAINZ_DATA_DIR}/solrdata
```

`MUSICBRAINZ_USE_HOST_LIVE_DATA=1` is the default, so live PostgreSQL, RabbitMQ, and Solr data are bind-mounted alongside the reusable dump caches. Set `MUSICBRAINZ_USE_HOST_LIVE_DATA=0` to use normal local Docker volumes for live service data, or `auto` to bind only when initialized host state already exists.

The setup wrapper creates script-managed bind volumes and emits them as `external: true` in `local/compose/bind-mounts.yml`, avoiding Compose warnings about pre-existing volumes without requiring the main compose file to know host-specific paths.

Why:
The bootstrap needs a predictable, inspectable data layout. A single data root stays the default for simplicity, while separate cache/live roots let operators put write-heavy PostgreSQL/Solr/RabbitMQ data on fast storage and large reusable dump archives on cheaper storage without editing tracked compose files.

### 4. The prebuilt `musicbrainz` image now overrides the bootstrap scripts

`build/musicbrainz-prebuilt/Dockerfile` now copies in local bootstrap helpers and patches upstream `InitDb.pl` at image build time.

Key changes:

- `/usr/local/bin/createdb.sh` is overridden
- `/usr/local/bin/fetch-dump.sh` is overridden
- `MusicBrainzDocker::ImportPatch` is injected into the `MBImport.pl` subprocess launched by `InitDb.pl`
- upstream `CreateSearchConfiguration.sql` execution is verified during image build so text search setup remains present before function creation
- the image ensures `/var/cache/musicbrainz/solr-backups` exists

Why:
The live compose service uses the prebuilt image path, so fixing only the source-tree scripts under `build/musicbrainz/scripts/` was not enough. The active runtime image had to be patched directly, while still preserving upstream search configuration setup that later SQL depends on.

### 5. Import path hardening for unstable large tables

The branch adds `build/musicbrainz-prebuilt/lib/MusicBrainzDocker/ImportPatch.pm` and host-side patch-source preparation in `scripts/setup_cache.py`.

The final design is:

- corruption-prone tables including `annotation`, `artist_credit`, `label`, `l_recording_work`, `recording`, `release_group`, `release_label`, `track`, and `url` prefer host-prepared clean source files under the persistent dump cache
- archive-mapped tables can fall back to direct `psql \copy ... FROM PROGRAM 'tar -xOf ...'` streaming when a verified host-prepared file is unavailable
- direct archive streaming currently covers fallback cases such as `cover_art_archive.cover_art`, `isrc`, `l_artist_recording`, `l_artist_work`, `l_label_recording`, `l_recording_url`, `l_release_group_release_group`, `l_release_url`, `medium`, `statistics.statistic`, and CD stub raw tables where host extraction failed read-back or produced corrupted rows
- patch sources are manifest-tracked with archive identity, target size, and read-back MD5
- stale temp files are removed before preparation
- extracted files are rejected if the host does not preserve the bytes that were just written
- patched imports use `psql \copy` instead of the default `DBD::Pg` streaming path

Why:
The default importer path produced non-deterministic row corruption on several large tables even when the archive itself validated cleanly. Narrow proof runs showed `psql \copy` from clean extracted files succeeded where the stock path did not.

### 6. PostgreSQL runtime tuning was raised for full bootstrap

`docker-compose.yml` and `docker-compose.alt.db-only-mirror.yml` now run PostgreSQL with more conservative checkpointing and less parallelism during bootstrap, including:

- `maintenance_work_mem=1024MB`
- `wal_compression=on`
- `max_wal_size=16GB`
- `checkpoint_timeout=30min`
- `checkpoint_completion_target=0.9`
- `max_parallel_maintenance_workers=0`
- `max_parallel_workers_per_gather=0`
- `max_parallel_workers=0`
- `jit=off`

Why:
After the data load was stabilized, the next failures were PostgreSQL internal errors and corrupted heap pages during primary-key/index creation under heavy checkpoint pressure and parallel workers. Reducing write-path stress and disabling parallel maintenance was required to finish bootstrap reliably.

### 7. Search runtime hardening

The branch builds the search image from Apache Solr plus the MusicBrainz Solr assets, installs the utilities needed to repair/load backup archives, and removes the first-run collection creation hook that conflicts with restoring backup archives into an already-managed SolrCloud state.

SIR is also patched so controlled single-entity reindexing can run serially, and `default/indexer.ini` lowers SIR/Solr batch and worker settings for this bootstrap path.

Why:
The desired steady state is to seed Solr once from verified backup archives, create any missing collections explicitly, and then keep search current through AMQP live indexing instead of repeatedly rebuilding everything from PostgreSQL.

### 8. Helper-script parity updates

`build/musicbrainz/scripts/createdb.sh` and `build/musicbrainz-dev/scripts/createdb.sh` were also updated so the non-prebuilt and development paths are not left with the original fragile behavior.

Why:
The active runtime fix lives in `build/musicbrainz-prebuilt`, but keeping the related helper scripts aligned makes the repo easier to reason about and avoids reintroducing the same class of failure elsewhere.

## Why This Exists

This was driven by repeated real failures during bootstrap:

- wrong DB name on first start
- empty or partially initialized databases being mistaken for healthy installs
- broken bind-mounted volumes
- importer corruption on a small set of large tables
- host/filesystem write-integrity failures leaving corrupted pre-extracted patch sources
- PostgreSQL corruption/internal failures during PK/index creation
- non-idempotent late bootstrap steps
- host runtime failures making Docker unable to start new containers
- reruns destroying healthy local volumes because Docker reports plain local volumes as `:` in `.Options`
- noisy expected probes against `musicbrainz_db` before that database exists

Each change in this branch exists because one of those failure modes was observed, reproduced, and then fixed with the smallest reliable change that kept the setup rerunnable.

## Validation

Validation performed for this branch/worktree includes:

- `bash -n ./setup-musicbrainz`
- `python3 -m py_compile scripts/setup_cache.py`
- `docker compose config --quiet`
- `git diff --check`
- required cached dump checksum verification
- Solr backup cache verification
- patch-source extraction with streaming MD5 and read-back verification

Observed successful end state from the full wrapper flow:

- `InitDb.pl succeeded`
- `docker compose up -d --no-build musicbrainz` started the app container
- homepage sanity check succeeded:

```bash
curl -fsS -o /dev/null 'http://localhost:5000/'
```

- API sanity check succeeded:

```bash
curl -fsS 'http://localhost:5000/ws/2/artist/b10bbbfc-cf9e-42e0-be17-e2c3e1d2600d?fmt=json' \
  | jq -e '.id == "b10bbbfc-cf9e-42e0-be17-e2c3e1d2600d"'
```

## Reviewer Notes

- The largest conceptual change is that setup now owns the full bootstrap orchestration rather than documenting a manual sequence.
- The storage default is intentionally a single configurable host data root; local Docker volumes are still available with `MUSICBRAINZ_USE_HOST_LIVE_DATA=0`.
- The branch is optimized for rerun safety and root-cause preservation, not blind retries.
- Ongoing DB replication is wired through the in-container cron path.
- Search freshness is handled by restoring Solr once from a verified local backup cache and then keeping it current through the built-in live-indexing path.
- The wrapper codifies repo-local search repairs that upstream does not currently handle reliably, instead of relying on one-off manual intervention.
