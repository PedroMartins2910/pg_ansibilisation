#!/bin/bash
# pg-ops VIP guard (runs as root, forever, from vip-guard.service).
# Invariant: the VIP lives ONLY on a node that is a writable primary.
#  - local PG down or in recovery          -> VIP down
#  - local PG primary, peers not primary   -> VIP up
#  - local PG primary AND a peer primary   -> split-brain: the node on the OLDER
#    (or equal) timeline releases the VIP and logs CRIT.
# Maintenance: touch /etc/pg-ops/vip.disabled to freeze the guard.
set -u
cd /
CTL=/usr/local/sbin/vip_ctl.sh
STATE_SQL="SELECT CASE WHEN pg_is_in_recovery() THEN 'standby' ELSE 'primary:' || substr(pg_walfile_name(pg_current_wal_lsn()), 1, 8) END"

check_once() {
  # Re-read config each loop so a major upgrade (new PG_BIN) is picked up.
  source /etc/pg-ops/pg.env
  source /etc/pg-ops/vip.env
  export PGPASSFILE
  if [[ "$VIP_ENABLED" != "true" || -f /etc/pg-ops/vip.disabled ]]; then return 0; fi

  local local_state peer_state my_tli peer_tli p
  local_state=$(runuser -u postgres -- "$PG_BIN/psql" -X -A -t -q -p "$PG_PORT" -d postgres -c "$STATE_SQL" 2>/dev/null)

  case "$local_state" in
    primary:*)
      my_tli=$((16#${local_state#primary:}))
      for p in $PG_PEERS; do
        peer_state=$(runuser -u postgres -- "$PG_BIN/psql" -X -A -t -q \
          "host=$p port=$PG_PORT user=$REPMGR_USER dbname=$REPMGR_DB connect_timeout=2" -c "$STATE_SQL" 2>/dev/null)
        if [[ "$peer_state" == primary:* ]]; then
          peer_tli=$((16#${peer_state#primary:}))
          if (( peer_tli >= my_tli )); then
            logger -p daemon.crit -t vip_guard "SPLIT-BRAIN: peer $p is primary on timeline $peer_tli >= local $my_tli - releasing VIP"
            "$CTL" down
            return 0
          fi
          logger -p daemon.crit -t vip_guard "SPLIT-BRAIN: peer $p is primary on OLDER timeline $peer_tli (local $my_tli) - keeping VIP"
        fi
      done
      "$CTL" up
      ;;
    *)
      "$CTL" down
      ;;
  esac
}

while true; do
  check_once
  sleep "${VIP_GUARD_INTERVAL:-3}"
done
