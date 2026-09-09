#!/bin/bash
# Re-enable sir live indexing after a replication run.
#
# LoadReplicationChanges sets sir.control.indexing_enabled = 0 at startup but
# only re-enables it via its packet-limit exit; the normal "Replication packet
# not available" exit (a mirror caught up with upstream) leaves indexing
# disabled, which starves the live indexer until manually reset.

set -eu

dockerize -wait "tcp://${MUSICBRAINZ_POSTGRES_SERVER}:5432" -timeout 60s sleep 0

run_psql() {
    PGPASSWORD="$POSTGRES_PASSWORD" psql \
        -h "$MUSICBRAINZ_POSTGRES_SERVER" \
        -U "$POSTGRES_USER" \
        -d "$POSTGRES_DB" \
        "$@"
}

# No-op when the sir schema (live indexing) is not installed.
if [ "$(run_psql -At -c "SELECT 1 WHERE to_regclass('sir.control') IS NOT NULL")" != "1" ]; then
    echo "sir schema not installed; skipping live-indexing re-enable"
    exit 0
fi

run_psql -c "UPDATE sir.control SET indexing_enabled = TRUE"
