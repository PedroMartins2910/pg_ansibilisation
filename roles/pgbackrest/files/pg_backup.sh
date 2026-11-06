#!/bin/bash
# Daily pgBackRest backup.   Usage: pg_backup.sh [--force] [--type=full|diff|incr]
#  - runs on the STANDBY (pgBackRest copies files from the standby, backup-standby=y)
#  - on the primary it exits 0 unless --force, or BACKUP_ALLOW_ON_PRIMARY=true and no
#    standby is streaming
#  - retention/expire is done by pgBackRest right after the backup
set -euo pipefail
source /etc/pg-ops/pg.env
source /etc/pg-ops/backup.env

LOG="$PGOPS_LOG_DIR/pg_backup.log"
log() { printf '%s pg_backup[%s] %s: %s\n' "$(date '+%F %T')" "$$" "$1" "$2" >> "$LOG"; }
status() {
  printf '{"status":"%s","detail":"%s","time":"%s","host":"%s"}\n' "$1" "$2" \
    "$(date '+%Y-%m-%dT%H:%M:%S%z')" "$(hostname -s)" > "$BACKUP_STATE_DIR/backup.status.tmp"
  mv "$BACKUP_STATE_DIR/backup.status.tmp" "$BACKUP_STATE_DIR/backup.status"
}
psql_local() { "$PG_BIN/psql" -X -A -t -q -p "$PG_PORT" -d postgres -c "$1"; }

FORCE=0
TYPE="$BACKUP_TYPE"
for a in "$@"; do
  case "$a" in
    --force) FORCE=1 ;;
    --type=*) TYPE="${a#--type=}" ;;
  esac
done

mkdir -p "$BACKUP_STATE_DIR"
exec 9>"$BACKUP_STATE_DIR/backup.lock"
if ! flock -n 9; then log WARN "another backup is running"; exit 0; fi

if [[ -f "$PGOPS_MAINTENANCE_FLAG" && $FORCE -eq 0 ]]; then
  log INFO "maintenance flag present - skipping"
  exit 0
fi

if ! in_recovery=$(psql_local "SELECT pg_is_in_recovery()"); then
  log ERROR "PostgreSQL is not reachable"
  logger -t pg-ops -p daemon.err "pg_backup: PostgreSQL not reachable"
  status failed "postgres unreachable"
  exit 1
fi

extra=()
if [[ "$in_recovery" != "t" ]]; then
  if [[ $FORCE -eq 0 ]]; then
    if [[ "$BACKUP_ALLOW_ON_PRIMARY" != "true" ]]; then
      log INFO "this node is the primary - the standby takes the backup"
      exit 0
    fi
    streaming=$(psql_local "SELECT count(*) FROM pg_stat_replication WHERE state = 'streaming'")
    if [[ "$streaming" != "0" ]]; then
      log INFO "primary with a streaming standby - the standby takes the backup"
      exit 0
    fi
    log WARN "no streaming standby - backing up from the PRIMARY"
  fi
  extra+=(--backup-standby=n)
fi

log INFO "starting $TYPE backup (stanza $PGBACKREST_STANZA, from $([[ "$in_recovery" == "t" ]] && echo standby || echo primary))"
status running "$TYPE"
if pgbackrest --stanza="$PGBACKREST_STANZA" --type="$TYPE" "${extra[@]}" backup >> "$LOG" 2>&1; then
  label=$(pgbackrest --stanza="$PGBACKREST_STANZA" --output=json info 2>/dev/null \
          | grep -o '"label":"[^"]*"' | tail -1 | cut -d'"' -f4)
  log INFO "backup OK: $label"
  status ok "$label"
  echo "$label"
else
  log ERROR "backup FAILED - see the pgBackRest log directory"
  logger -t pg-ops -p daemon.err "pg_backup: pgBackRest backup failed"
  status failed "$TYPE"
  exit 1
fi
