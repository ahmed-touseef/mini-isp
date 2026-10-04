#!/usr/bin/env bash
# Phase 4c: TI-LFA on the core routers' internal links, applied live. Run with sudo.
set -u
cd "$(dirname "$0")"
P=clab-miniiliad
if grep -q "fast-reroute ti-lfa" configs/milan.conf; then echo "Phase 4c already applied"; exit 0; fi

tilfa() {  # node, internal interfaces
  local n=$1; shift
  local args=(-c "conf t") cfg=""
  for i in "$@"; do
    args+=(-c "interface $i" -c "isis fast-reroute ti-lfa" -c "exit")
    cfg+="interface $i"$'\n isis fast-reroute ti-lfa\nexit\n!\n'
  done
  docker exec $P-$n vtysh "${args[@]}"
  sed -i '/^end$/d' configs/$n.conf
  printf '%s' "$cfg" >> configs/$n.conf
  echo "TI-LFA enabled on $n: $*"
}
tilfa milan   eth1 eth2 eth3 eth4
tilfa rome    eth1 eth2 eth3
tilfa naples  eth1 eth2 eth3
tilfa bologna eth1 eth2
