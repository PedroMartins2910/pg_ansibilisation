#!/bin/bash
# pg-ops: add / remove the PostgreSQL VIP on this host.  Usage: vip_ctl.sh up|down|status
set -u
source /etc/pg-ops/vip.env

has_vip() {
  ip -o -4 addr show dev "$VIP_INTERFACE" | awk '{print $4}' | grep -qx "${VIP_ADDRESS}/${VIP_PREFIX}"
}

case "${1:-}" in
  up)
    if [[ "$VIP_ENABLED" != "true" ]]; then exit 0; fi
    if ! has_vip; then
      ip addr add "${VIP_ADDRESS}/${VIP_PREFIX}" dev "$VIP_INTERFACE" \
        && logger -t vip_ctl "VIP ${VIP_ADDRESS} added on ${VIP_INTERFACE}"
      # gratuitous ARP so switches/clients learn the new MAC quickly
      arping -q -U -c 3 -I "$VIP_INTERFACE" "$VIP_ADDRESS" >/dev/null 2>&1 &
    fi
    ;;
  down)
    if has_vip; then
      ip addr del "${VIP_ADDRESS}/${VIP_PREFIX}" dev "$VIP_INTERFACE" \
        && logger -t vip_ctl "VIP ${VIP_ADDRESS} removed from ${VIP_INTERFACE}"
    fi
    ;;
  status)
    if has_vip; then echo up; else echo down; fi
    ;;
  *)
    echo "usage: $0 up|down|status" >&2
    exit 2
    ;;
esac
exit 0
