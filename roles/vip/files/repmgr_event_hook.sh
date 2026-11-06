#!/bin/bash
# repmgr event_notification_command:  repmgr_event_hook.sh %n %e %s "%t" "%d"
# Runs as postgres. Moves the VIP immediately after promote / switchover / follow
# (vip-guard converges anyway within a few seconds; this just makes it faster).
NODE_ID="${1:-}"; EVENT="${2:-}"; SUCCESS="${3:-}"; TS="${4:-}"; DETAILS="${5:-}"
source /etc/pg-ops/pg.env
source /etc/pg-ops/vip.env

logger -t repmgr-event "node_id=$NODE_ID event=$EVENT success=$SUCCESS ts=$TS details=$DETAILS"
[[ "$VIP_ENABLED" == "true" ]] || exit 0
[[ "$SUCCESS" == "1" ]] || exit 0

case "$EVENT" in
  standby_promote|repmgrd_failover_promote|standby_switchover|standby_follow|repmgrd_failover_follow|node_rejoin) ;;
  *) exit 0 ;;
esac

# Trust the database, not the event name.
state=$("$PG_BIN/psql" -X -A -t -q -p "$PG_PORT" -d postgres -c "SELECT pg_is_in_recovery()" 2>/dev/null)
if [[ "$state" == "f" ]]; then
  for p in $PG_PEERS; do
    timeout 10 ssh -o BatchMode=yes -o ConnectTimeout=3 -o StrictHostKeyChecking=accept-new \
      "postgres@$p" sudo -n /usr/local/sbin/vip_ctl.sh down \
      || logger -t repmgr-event "could not release VIP on peer $p (unreachable?)"
  done
  sudo -n /usr/local/sbin/vip_ctl.sh up
else
  sudo -n /usr/local/sbin/vip_ctl.sh down
fi
exit 0
