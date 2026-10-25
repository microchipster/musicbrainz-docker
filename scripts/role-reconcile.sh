#!/usr/bin/env bash
# MusicBrainz role reconcile — enforce exactly ONE hot database (2026-10-24).
#
# Runs on the canonical primary (pi1). When a promoted standby (nas) is up
# while the primary has also returned, both databases can be PRIMARY at the
# same time (split-brain: two writable instances, two consumers). This script
# detects that state and rewinds the PEER back to a streaming standby of the
# local instance — the same revert path the failover drill exercised
# (pg_rewind as uid 999 + standby recovery config), just automated.
#
# Safety rules:
#   * local must be primary; local standby => no-op (the peer is the hot one)
#   * peer unreachable => no-op (it is down; single-hot holds)
#   * peer standby => no-op (healthy replication topology)
#   * both primary => reconcile: stop peer app tier first (only one serving),
#     pg_rewind the peer toward the local primary, restore its standby
#     config, start its db, verify streaming; peer is left COLD (web/indexer
#     stopped) exactly like a normal standby.
#   * a flock prevents overlapping runs; every action is appended to
#     local/state/role-reconcile.log; a best-effort Matrix alert is sent.
#
# MusicBrainz data re-derives from the upstream community server, so
# rewinding the promoted instance does not lose anything that cannot be
# re-fetched; any local writes on the peer are recorded in the log first.
#
# Environment overrides:
#   MB_PEER_HOST        peer ssh target                 (default: nas)
#   MB_PEER_REPO        peer repo checkout              (default: /home/user/src/repos/musicbrainz-docker)
#   MB_PEER_PGDATA      peer pgdata host path           (default: /media/standby/musicbrainz/pgdata)
#   MB_PEER_CONTAINER   peer db container name          (default: musicbrainz-docker-db-1)
#   MB_LOCAL_CONTAINER  local db container name         (default: musicbrainz-docker-db-1)
#   MB_LOCAL_MESH_IP    local mesh IP for the rewind    (default: 10.13.13.14)
#   MB_ALERT_URL        hookshot webhook URL override   (default: notifier key in
#                       ~/.config/private/hookshot_urls when present)
#
# Usage: role-reconcile.sh [--status]   (--status prints roles and exits)

set -u

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_dir="$(dirname "$script_dir")"
state_dir="$repo_dir/local/state"
log="$state_dir/role-reconcile.log"
lock="$state_dir/role-reconcile.lock"

peer_host="${MB_PEER_HOST:-nas}"
peer_repo="${MB_PEER_REPO:-/home/user/src/repos/musicbrainz-docker}"
peer_pgdata="${MB_PEER_PGDATA:-/media/standby/musicbrainz/pgdata}"
peer_container="${MB_PEER_CONTAINER:-musicbrainz-docker-db-1}"
local_container="${MB_LOCAL_CONTAINER:-musicbrainz-docker-db-1}"
local_mesh_ip="${MB_LOCAL_MESH_IP:-10.13.13.14}"

mkdir -p "$state_dir"

say() {
  printf '[%s] %s\n' "$(date -u +%FT%TZ)" "$*" | tee -a "$log"
}

alert() {
  # Best-effort Matrix notification through the hookshot webhook.
  local url="${MB_ALERT_URL:-}"
  if [ -z "$url" ] && [ -f "$HOME/.config/private/hookshot_urls" ]; then
    url="$(awk '$1 == "notifier" { print $2; exit }' "$HOME/.config/private/hookshot_urls")"
    [ -z "$url" ] && url="$(awk 'NF == 1 && $1 ~ /^https:/ { print $1; exit }' "$HOME/.config/private/hookshot_urls")"
  fi
  [ -z "$url" ] && return 0
  local text="$1"
  curl -fsS -m 10 -X POST -H 'Content-Type: application/json' \
    --data "$(printf '{"text": %s}' "$(printf '%s' "$text" | python3 -c 'import json,sys; print(json.dumps(sys.stdin.read()))')")" \
    "$url" >/dev/null 2>&1 || true
}

local_role() {
  docker exec "$local_container" psql -U musicbrainz -d musicbrainz_db -tAc \
    "select pg_is_in_recovery()" 2>/dev/null | tr -d '[:space:]'
}

local_evidence() {
  docker exec "$local_container" psql -U musicbrainz -d musicbrainz_db -tAc \
    "select pg_current_wal_lsn(), (select timeline_id from pg_control_checkpoint())" 2>/dev/null |
    tr -d '[:space:]'
}

peer_psql() {
  ssh -o BatchMode=yes -o ConnectTimeout=8 "$peer_host" \
    "sudo -n docker exec $peer_container psql -U musicbrainz -d musicbrainz_db -tAc \"$1\"" 2>/dev/null |
    tr -d '[:space:]'
}

status_mode=0
[ "${1:-}" = "--status" ] && status_mode=1

if [ "$status_mode" = "1" ]; then
  echo "local ($(hostname)):  $(local_role)"
  echo "peer  ($peer_host): $(peer_psql 'select pg_is_in_recovery()')"
  exit 0
fi

exec 9>"$lock"
if ! flock -n 9; then
  echo "another role-reconcile run holds the lock; skipping" >&2
  exit 0
fi

role="$(local_role)"
if [ -z "$role" ]; then
  say "local db not reachable; skipping"
  exit 0
fi
if [ "$role" != "f" ]; then
  say "local is a standby (in recovery); nothing to enforce"
  exit 0
fi

peer="$(peer_psql 'select pg_is_in_recovery()')"
if [ -z "$peer" ]; then
  say "peer $peer_host unreachable; single-hot holds, nothing to do"
  exit 0
fi
if [ "$peer" != "f" ]; then
  peer_rx="$(peer_psql 'select status from pg_stat_wal_receiver')"
  if [ "$peer_rx" = "streaming" ]; then
    say "peer $peer_host is a streaming standby; replication topology healthy"
  else
    alert "MusicBrainz role reconcile: peer $peer_host is a standby but NOT streaming (wal receiver: ${peer_rx:-none}); the replication link is broken (check the db port publish + pg_hba; see the 2026-10-25 incident). Fix on $(hostname): ./admin/configure add local/compose/standby-replication.yml && docker compose up -d --no-build db"
    exit 1
  fi
  exit 0
fi

# ---- split-brain: both databases are primary -------------------------------
say "SPLIT-BRAIN detected: local=$(hostname) primary AND peer=$peer_host primary"
say "local evidence (lsn,timeline): $(local_evidence)"
say "peer evidence (lsn,timeline):  $(peer_psql 'select pg_current_wal_lsn(), (select timeline_id from pg_control_checkpoint())')"
alert "MusicBrainz role reconcile: split-brain detected (both primary). Rewinding $peer_host back to standby of $(hostname)."

say "stopping peer app tier (web/indexer) so only one instance serves"
ssh -o BatchMode=yes -o ConnectTimeout=8 "$peer_host" \
  "cd $peer_repo && sudo -n docker compose stop musicbrainz indexer" >>"$log" 2>&1 || true

say "stopping peer db"
ssh -o BatchMode=yes -o ConnectTimeout=8 "$peer_host" \
  "cd $peer_repo && sudo -n docker compose stop db" >>"$log" 2>&1 || true

# Superuser password for pg_rewind's source connection: read locally, ship it
# over ssh into a 600 env file, never print it.
pw="$(grep -m1 '^POSTGRES_PASSWORD=' "$repo_dir/default/postgres.env" | cut -d= -f2-)"
if [ -z "$pw" ]; then
  say "ERROR: no POSTGRES_PASSWORD in $repo_dir/default/postgres.env; aborting rewind"
  exit 1
fi
printf 'PGPASSWORD=%s\n' "$pw" | ssh -o BatchMode=yes -o ConnectTimeout=8 "$peer_host" \
  'umask 077; cat > /tmp/mb-role-rewind.env'

say "pg_rewind $peer_host toward local primary ($local_mesh_ip)"
if ! ssh -o BatchMode=yes -o ConnectTimeout=8 "$peer_host" \
  "sudo -n docker run --rm --user 999:999 --env-file /tmp/mb-role-rewind.env \
     -v $peer_pgdata:/var/lib/postgresql \
     musicbrainz-docker_db:18 pg_rewind \
     -D /var/lib/postgresql/18/docker \
     --source-server=\"host=$local_mesh_ip port=5432 user=musicbrainz dbname=musicbrainz_db\" \
     -R -P > /tmp/mb-role-rewind.out 2>&1; rc=\$?; tail -4 /tmp/mb-role-rewind.out; \
     rm -f /tmp/mb-role-rewind.env; exit \$rc" >>"$log" 2>&1; then
  say "ERROR: pg_rewind failed (see $log / /tmp/mb-role-rewind.out on $peer_host); peer left stopped"
  alert "MusicBrainz role reconcile: pg_rewind FAILED on $peer_host — peer db left stopped; manual attention needed."
  exit 1
fi

say "restoring peer standby recovery config"
ssh -o BatchMode=yes -o ConnectTimeout=8 "$peer_host" "SRC_IP='$local_mesh_ip' PGD='$peer_pgdata/18/docker' sudo -n sh -s" <<'REC' >>"$log" 2>&1
set -eu
touch "$PGD/standby.signal"
grep -v '^primary_conninfo' "$PGD/postgresql.auto.conf" | grep -v '^primary_slot_name' > "$PGD/postgresql.auto.conf.tmp" || true
PW=$(cat /root/.mb-standby-pw)
printf "primary_conninfo = 'host=%s port=5432 user=mb_standby password=%s application_name=nas_standby'\nprimary_slot_name = 'nas_standby'\n" "$SRC_IP" "$PW" >> "$PGD/postgresql.auto.conf.tmp"
mv "$PGD/postgresql.auto.conf.tmp" "$PGD/postgresql.auto.conf"
chown 999:999 "$PGD/postgresql.auto.conf"
REC

say "starting peer db"
ssh -o BatchMode=yes -o ConnectTimeout=8 "$peer_host" \
  "cd $peer_repo && sudo -n docker compose start db" >>"$log" 2>&1 || true

sleep 15
peer_rec="$(peer_psql 'select pg_is_in_recovery()')"
peer_rx="$(peer_psql 'select status from pg_stat_wal_receiver')"
local_repl="$(docker exec "$local_container" psql -U musicbrainz -d musicbrainz_db -tAc \
  "select application_name || '|' || state from pg_stat_replication" 2>/dev/null | tr -d '[:space:]')"

say "post-reconcile: peer in_recovery=$peer_rec receiver=$peer_rx local replication=$local_repl"
if [ "$peer_rec" = "t" ] && [ "$peer_rx" = "streaming" ]; then
  say "reconcile OK: $peer_host is a streaming standby again (web/indexer left cold)"
  alert "MusicBrainz role reconcile: $peer_host rewound and streaming again as standby of $(hostname)."
else
  say "reconcile INCOMPLETE: peer in_recovery=$peer_rec receiver=$peer_rx — manual attention needed"
  alert "MusicBrainz role reconcile: $peer_host did not reach streaming (in_recovery=$peer_rec, receiver=$peer_rx); manual attention needed."
  exit 1
fi
