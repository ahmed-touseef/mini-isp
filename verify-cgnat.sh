#!/usr/bin/env bash
# Phase 5b checks: CGNAT on the BNG. Run with sudo.
P=clab-miniiliad

echo "== NAT rule on the BNG =="
docker exec $P-bng nft list table ip cgnat

echo "== Homes reach the internet and the peers through CGNAT =="
for h in home1 home2; do
  for d in 198.51.100.1 198.18.1.1 198.18.2.1; do
    docker exec $P-$h ping -c2 -W1 $d >/dev/null && echo "  OK   $h -> $d" || echo "  FAIL $h -> $d"
  done
done
echo "-- traceroute from home1 to the internet server"
docker exec $P-home1 traceroute -n 198.51.100.1

echo "== Live translations on the BNG (private -> public) =="
docker exec $P-bng conntrack -L -p icmp 2>/dev/null

echo "== Unsolicited traffic from the internet to the pool =="
docker exec $P-internet ping -c2 -W1 192.0.2.33 >/dev/null && echo "  REACHABLE (unexpected)" || echo "  BLOCKED internet -> 192.0.2.33 (no translation exists, nothing to deliver)"
