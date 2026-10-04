#!/usr/bin/env bash
# Phase 2: migrate the core from OSPF to IS-IS with no downtime. Run with sudo.
#   ./phase2-isis.sh add     run IS-IS alongside OSPF (OSPF still preferred)
#   ./phase2-isis.sh remove  remove OSPF, IS-IS takes over, save configs
set -u
P=clab-miniiliad
declare -A ID=([milan]=1 [rome]=2 [naples]=3 [bologna]=4)

case "${1:-}" in
add)
  for r in "${!ID[@]}"; do
    n=${ID[$r]}
    docker exec $P-$r vtysh -c "conf t" \
      -c "router isis CORE" -c "net 49.0001.0102.5500.000$n.00" \
      -c "is-type level-2-only" -c "metric-style wide" -c "exit" \
      -c "interface lo" -c "ip router isis CORE" -c "isis passive" -c "exit" \
      -c "interface eth1" -c "ip router isis CORE" -c "isis network point-to-point" -c "exit" \
      -c "interface eth2" -c "ip router isis CORE" -c "isis network point-to-point" -c "exit"
    echo "IS-IS added on $r"
  done ;;
remove)
  for r in "${!ID[@]}"; do
    docker exec $P-$r vtysh -c "conf t" \
      -c "interface lo" -c "no ip ospf area 0" -c "no ip ospf passive" -c "exit" \
      -c "interface eth1" -c "no ip ospf area 0" -c "no ip ospf network point-to-point" -c "exit" \
      -c "interface eth2" -c "no ip ospf area 0" -c "no ip ospf network point-to-point" -c "exit" \
      -c "no router ospf"
    docker exec $P-$r vtysh -c "show running-config" | sed '1,/^Current configuration:/d' > configs/$r.conf
    echo "OSPF removed on $r, config saved to configs/$r.conf"
  done ;;
*) echo "Usage: $0 add|remove"; exit 1 ;;
esac
