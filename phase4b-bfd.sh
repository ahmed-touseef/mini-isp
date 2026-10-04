#!/usr/bin/env bash
# Phase 4b: BFD on every internal IS-IS link (100 ms x 3 = 300 ms detection), applied live. Run with sudo.
set -u
cd "$(dirname "$0")"
P=clab-miniiliad
if grep -q "isis bfd" configs/milan.conf; then echo "Phase 4b already applied"; exit 0; fi

bfd() {  # node, internal interfaces
  local n=$1; shift
  local args=(-c "conf t" -c "bfd" -c "profile FAST" -c "detect-multiplier 3" -c "receive-interval 100" -c "transmit-interval 100" -c "exit" -c "exit")
  local cfg=$'bfd\n profile FAST\n  detect-multiplier 3\n  receive-interval 100\n  transmit-interval 100\n exit\nexit\n!\n'
  for i in "$@"; do
    args+=(-c "interface $i" -c "isis bfd" -c "isis bfd profile FAST" -c "exit")
    cfg+="interface $i"$'\n isis bfd\n isis bfd profile FAST\nexit\n!\n'
  done
  docker exec $P-$n vtysh "${args[@]}"
  sed -i '/^end$/d' configs/$n.conf
  printf '%s' "$cfg" >> configs/$n.conf
  echo "BFD enabled on $n: $*"
}
bfd milan   eth1 eth2 eth3 eth4
bfd rome    eth1 eth2 eth3
bfd naples  eth1 eth2 eth3
bfd bologna eth1 eth2
bfd rr1 eth1
bfd rr2 eth1
bfd br1 eth1
bfd br2 eth1
