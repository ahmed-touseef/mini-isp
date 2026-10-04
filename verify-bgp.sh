#!/usr/bin/env bash
# Phase 3a checks: iBGP through route reflectors. Run with sudo.
P=clab-miniiliad
CORE="milan rome naples bologna"

bgp_ready() {
  for r in $CORE; do
    n=$(docker exec $P-$r vtysh -c "show ip route bgp" 2>/dev/null | grep -c "^B>")
    [ "$n" -ge 3 ] || return 1
  done
}

echo "== Waiting for every core router to install 3 BGP routes =="
for i in $(seq 1 120); do
  bgp_ready && { echo "  BGP converged after ${i}s"; break; }
  sleep 1
done

echo "== rr1 sessions (expect 4 clients + rr2 Established) =="
docker exec $P-rr1 vtysh -c "show bgp ipv4 unicast summary"

echo "== milan BGP table =="
docker exec $P-milan vtysh -c "show bgp ipv4 unicast"

echo "== How milan reaches the naples pool (BGP next hop resolved via IS-IS) =="
docker exec $P-milan vtysh -c "show ip route 192.0.2.128/26"

echo "== Customer to customer pings from milan's LAN =="
for ip in 192.0.2.65 192.0.2.129 192.0.2.193; do
  docker exec $P-milan ping -c2 -W1 -I 192.0.2.1 $ip >/dev/null && echo "OK   $ip" || echo "FAIL $ip"
done

echo "== Redundancy test: shut every session on rr1, routes must survive via rr2 =="
docker exec $P-rr1 vtysh -c "conf t" -c "router bgp 65000" -c "neighbor CLIENTS shutdown" -c "neighbor 10.255.0.12 shutdown"
sleep 3
n=$(docker exec $P-milan vtysh -c "show ip route bgp" | grep -c "^B>")
echo "  milan still has $n/3 BGP routes"
docker exec $P-milan ping -c2 -W1 -I 192.0.2.1 192.0.2.129 >/dev/null && echo "  OK   traffic still flows" || echo "  FAIL traffic lost"
docker exec $P-rr1 vtysh -c "conf t" -c "router bgp 65000" -c "no neighbor CLIENTS shutdown" -c "no neighbor 10.255.0.12 shutdown"
echo "rr1 restored."
