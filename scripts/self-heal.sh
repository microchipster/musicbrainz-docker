#!/usr/bin/env bash
# Description: Scheduled self-healing for a musicbrainz-docker mirror deployment.
#
# Runs `verify-musicbrainz --scope full` on a timer. When verification fails,
# applies escalating, idempotent remedies:
#   Tier 0 (always, safe)  restart the live indexer, re-enable sir indexing,
#                          requeue pending rows that exhausted their retries.
#   Tier 1 (stale mirror)  pause the indexer, run a replication catch-up,
#                          re-enable indexing, resume the indexer.
#   Tier 2 (persistent,    the proven clean-slate playbook: wipe the Solr data
#          rare)           directory and rebuild search from the verified local
#                          backup cache via ./setup-musicbrainz. The wipe clears
#                          lost ZooKeeper coordination state, not source data.
# Tier 2 only runs after 3 consecutive failed verifications and at most once
# per day. Set MUSICBRAINZ_AUTO_HEAL=0 to disable all healing actions.

set -uo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_DIR" || exit 1

STATE_DIR="$REPO_DIR/local/state"
LOG_FILE="${MUSICBRAINZ_SELFHEAL_LOG:-$STATE_DIR/self-heal.log}"
LOCK_FILE="$STATE_DIR/self-heal.lock"
FAIL_COUNTER="$STATE_DIR/self-heal-consecutive-failures"
WIPE_STAMP="$STATE_DIR/self-heal-last-wipe"
VERIFY_LOG="$STATE_DIR/self-heal-verify.log"

TIER2_AFTER_FAILURES="${MUSICBRAINZ_SELFHEAL_TIER2_AFTER_FAILURES:-3}"
TIER1_MAX_WAIT="${MUSICBRAINZ_SELFHEAL_TIER1_MAX_WAIT:-14400}"

log() { printf '[%s] %s\n' "$(date '+%F %T')" "$*" | tee -a "$LOG_FILE"; }

solrdata_dir() {
  docker volume inspect -f '{{ index .Options "device" }}' musicbrainz-docker_solrdata 2> /dev/null
}

pause_indexer() { docker compose stop indexer > /dev/null 2>&1 || :; }

resume_indexer() { docker compose up -d --no-build indexer > /dev/null 2>&1 || :; }

tier0_restart_indexing() {
  log "Tier 0: restarting live indexing"
  resume_indexer
  docker compose exec -T musicbrainz /usr/local/bin/enable-sir-indexing.sh > /dev/null 2>&1 \
    || log "Tier 0: enable-sir-indexing failed (sir schema may be absent; ignoring)"
  if docker compose exec -T db psql -U musicbrainz -d musicbrainz_db -At -c \
    "SELECT to_regclass('sir.pending_data') IS NOT NULL" 2> /dev/null | grep -qx t; then
    printf "UPDATE sir.pending_data SET attempts = 0, last_attempted = NULL WHERE attempts >= 4;\n" \
      | docker compose exec -T db psql -U musicbrainz -d musicbrainz_db -f - > /dev/null 2>&1 \
      && log "Tier 0: requeued exhausted pending rows"
  fi
}

replication_sequence() {
  docker compose exec -T db psql -U musicbrainz -d musicbrainz_db -At -c \
    "SELECT current_replication_sequence FROM musicbrainz.replication_control ORDER BY id DESC LIMIT 1" 2> /dev/null
}

tier1_catch_up_replication() {
  log "Tier 1: replication is stale; running catch-up with the indexer paused"
  pause_indexer
  docker compose exec -d musicbrainz replication.sh > /dev/null 2>&1 || {
    log "Tier 1: could not start replication.sh"
    resume_indexer
    return
  }

  local last="" current stalls=0 waited=0
  while [ "$waited" -lt "$TIER1_MAX_WAIT" ]; do
    sleep 300
    waited=$((waited + 300))
    current="$(replication_sequence)"
    if [ -n "$current" ] && [ "$current" = "$last" ]; then
      stalls=$((stalls + 1))
      [ "$stalls" -ge 2 ] && break
    else
      stalls=0
    fi
    last="$current"
    log "Tier 1: catch-up in progress (sequence ${current:-unknown})"
  done

  docker compose exec -T musicbrainz /usr/local/bin/enable-sir-indexing.sh > /dev/null 2>&1 || :
  resume_indexer
  log "Tier 1: catch-up finished at sequence $(replication_sequence || echo unknown); indexing re-enabled"
}

tier2_rebuild_search() {
  log "Tier 2: rebuilding Solr from the verified backup cache (search-only downtime, ~3-4h)"

  local solrdata wipe_dir
  solrdata="$(solrdata_dir)"
  if [ -z "$solrdata" ] || [ ! -d "$solrdata" ]; then
    log "Tier 2: could not resolve the solrdata bind-mount device; aborting"
    return
  fi

  if ! sudo -n true 2> /dev/null; then
    log "Tier 2: passwordless sudo unavailable; cannot wipe $solrdata; aborting"
    return
  fi

  docker compose stop indexer search > /dev/null 2>&1 || :
  wipe_dir="$(realpath -m "$solrdata")"
  case "$wipe_dir" in / | /var | /etc | /usr | /home)
    log "Tier 2: refusing to wipe unsafe path $wipe_dir; aborting"
    docker compose up -d --no-build search > /dev/null 2>&1 || :
    return
    ;;
  esac
  if sudo -n find "$wipe_dir" -mindepth 1 -maxdepth 1 -exec rm -rf {} +; then
    log "Tier 2: wiped $wipe_dir"
  else
    log "Tier 2: wipe failed; aborting"
    return
  fi
  docker compose up -d --no-build search > /dev/null 2>&1 || :

  local token
  token="$(head -1 "$REPO_DIR/local/secrets/metabrainz_access_token" 2> /dev/null || :)"
  if [ -z "$token" ]; then
    log "Tier 2: replication token missing at local/secrets/metabrainz_access_token; aborting"
    return
  fi

  log "Tier 2: running ./setup-musicbrainz to rebuild and verify search"
  if ./setup-musicbrainz "$token" "$(dirname "$wipe_dir")" >> "$LOG_FILE" 2>&1; then
    log "Tier 2: rebuild completed and verified"
    printf '0\n' > "$FAIL_COUNTER"
  else
    log "Tier 2: setup failed; inspect $LOG_FILE"
  fi
  date '+%F' > "$WIPE_STAMP"
}

main() {
  mkdir -p "$STATE_DIR"

  if [ "${MUSICBRAINZ_AUTO_HEAL:-1}" = "0" ]; then
    log "auto-heal disabled (MUSICBRAINZ_AUTO_HEAL=0); nothing to do"
    exit 0
  fi

  exec 9> "$LOCK_FILE"
  if ! flock -n 9; then
    log "another self-heal run is active; skipping"
    exit 0
  fi

  if ./verify-musicbrainz --scope full --quiet > "$VERIFY_LOG" 2>&1; then
    log "deployment healthy; no action needed"
    printf '0\n' > "$FAIL_COUNTER"
    exit 0
  fi

  local failures
  failures="$(( $(cat "$FAIL_COUNTER" 2> /dev/null || echo 0) + 1 ))"
  printf '%s\n' "$failures" > "$FAIL_COUNTER"
  log "verification FAILED (consecutive: $failures); output in $VERIFY_LOG"
  grep -aE 'Verified|Failed|stale|Live indexing|Replication|Solr|None of' "$VERIFY_LOG" | tail -5 | while IFS= read -r line; do log "  verify: $line"; done

  tier0_restart_indexing

  if grep -aq 'Replication is stale' "$VERIFY_LOG"; then
    tier1_catch_up_replication
    return
  fi

  if [ "$failures" -ge "$TIER2_AFTER_FAILURES" ]; then
    local today last_wipe
    today="$(date '+%F')"
    last_wipe="$(cat "$WIPE_STAMP" 2> /dev/null || echo never)"
    if [ "$last_wipe" = "$today" ]; then
      log "Tier 2: already rebuilt today; waiting for the next window"
      return
    fi
    tier2_rebuild_search
  fi
}

main "$@"
