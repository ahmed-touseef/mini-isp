#!/usr/bin/env bash
# Phase 3b checks: internet edge with two upstreams. Run with sudo.
P=clab-miniiliad
CORE="milan rome naples bologna"
NETS="198.51.100.0/24 203.0.113.0/24"

edge_ready() {
  for r in $CORE; do
    t=$(docker exec $P-$r vtysh -c "show ip route bgp" 2>/dev/null)
    for n in $NETS; do echo "$t" | grep -q "^B>.* $n" || return 1; done
  done
}

echo "== Waiting for every core router to learn the internet prefixes =="
for i in $(seq 1 120); do
  edge_ready && { echo "  edge converged after ${i}s"; break; }
  sleep 1
done

echo "== Sessions on the border routers (2 RRs + 1 upstream each) =="
for b in br1 br2; do
  echo "-- $b"
  docker exec $P-$b vtysh -c "show bgp ipv4 unicast summary" | grep -E "^Neighbor|^10\."
done

echo "== What br1 announces to Arelion (expect only 192.0.2.0/24) =="
docker exec $P-br1 vtysh -c "show bgp ipv4 unicast neighbors 10.100.1.1 advertised-routes"

echo "== How the internet sees our network =="
docker exec $P-internet vtysh -c "show bgp ipv4 unicast 192.0.2.0/24"

echo "== Exit chosen by each core router for 198.51.100.0/24 (hot potato) =="
for r in $CORE; do
  nh=$(docker exec $P-$r vtysh -c "show ip route 198.51.100.0/24" | grep -m1 -o "10\.255\.0\.[0-9]*")
  case $nh in 10.255.0.5) ex="br1 -> Arelion";; 10.255.0.6) ex="br2 -> Cogent";; *) ex="?";; esac
  printf "  %-8s next hop %-11s %s\n" $r "$nh" "$ex"
done

echo "== Customers reaching the internet server 198.51.100.1 =="
for r in $CORE; do
  src=$(docker exec $P-$r ip -4 -o addr show cust0 | awk '{print $4}' | cut -d/ -f1)
  docker exec $P-$r ping -c2 -W1 -I $src 198.51.100.1 >/dev/null && echo "OK   $r ($src)" || echo "FAIL $r ($src)"
done
echo "-- traceroute from milan's customer LAN"
docker exec $P-milan traceroute -n -s 192.0.2.1 198.51.100.1

echo "== Upstream failover: shut br1's session to Arelion =="
docker exec $P-br1 vtysh -c "conf t" -c "router bgp 65000" -c "neighbor 10.100.1.1 shutdown"
for i in $(seq 1 60); do
  docker exec $P-milan vtysh -c "show ip route 198.51.100.0/24" | grep -q "10.255.0.6" && { echo "  milan moved to br2 (Cogent) after ${i}s"; break; }
  sleep 1
done
docker exec $P-milan ping -c2 -W1 -I 192.0.2.1 198.51.100.1 >/dev/null && echo "  OK   internet still reachable" || echo "  FAIL internet lost"
docker exec $P-br1 vtysh -c "conf t" -c "router bgp 65000" -c "no neighbor 10.100.1.1 shutdown"
echo "Arelion session restored."
