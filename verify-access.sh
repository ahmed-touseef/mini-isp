#!/usr/bin/env bash
# Phase 5a checks: access network with DHCP. Run with sudo.
P=clab-miniiliad

echo "== Waiting for the BNG to join the backbone =="
for i in $(seq 1 90); do
  docker exec $P-rome ip route show 10.255.0.7 | grep -q "encap mpls" && { echo "  ready after ${i}s"; break; }
  sleep 1
done

echo "== DHCP leases handed out by the BNG =="
docker exec $P-bng cat /tmp/dnsmasq.leases

for h in home1 home2; do
  echo "== $h =="
  docker exec $P-$h ip -4 -br addr show eth1
  docker exec $P-$h ip route
  docker exec $P-$h ping -c2 -W1 100.64.0.1 >/dev/null && echo "  OK   gateway 100.64.0.1" || echo "  FAIL gateway 100.64.0.1"
done

echo "== The BNG in the backbone =="
docker exec $P-milan vtysh -c "show isis neighbor" | grep -E "System|bng"
docker exec $P-milan vtysh -c "show bfd peers brief" | grep -E "Status|10.0.0.17"
echo "-- rome reaches the BNG over MPLS (expect encap mpls 16007)"
docker exec $P-rome ip route show 10.255.0.7
echo "-- the CGNAT pool 192.0.2.32/28 is in BGP"
docker exec $P-rr1 vtysh -c "show bgp ipv4 unicast 192.0.2.32/28" | grep -E "^  Local|from|best"

echo "== Before CGNAT: homes cannot reach the internet yet =="
docker exec $P-home1 ping -c2 -W1 198.51.100.1 >/dev/null && echo "  OK   home1 -> internet" || echo "  FAIL home1 -> internet (expected: 100.64.0.0/24 is private and not routed)"
