#!/usr/bin/env bash
# Phase 3d checks: peering at the MIX internet exchange. Run with sudo.
P=clab-miniiliad
CUST="milan:192.0.2.1 rome:192.0.2.65 naples:192.0.2.129 bologna:192.0.2.193"

br1_via() { docker exec $P-br1 vtysh -c "show ip route $1" | grep -qF "$2"; }
wait_br1() {  # prefix next_hop label
  for i in $(seq 1 90); do br1_via $1 $2 && { echo "  $1 via $3 after ${i}s"; return; }; sleep 1; done
  echo "  TIMEOUT: $1 via $3"
}
pings() {
  for c in $CUST; do r=${c%%:*}; s=${c#*:}; out="  $r:"
    for d in 198.18.1.1 198.18.2.1; do
      docker exec $P-$r ping -c2 -W1 -I $s $d >/dev/null && out="$out OK($d)" || out="$out FAIL($d)"
    done
    echo "$out"
  done
}

echo "== 1. br1 reaches both peers across the exchange =="
wait_br1 198.18.1.0/24 10.200.0.11 "MIX (fastweb)"
wait_br1 198.18.2.0/24 10.200.0.12 "MIX (netflix)"

echo "== 2. Route server sessions (expect 3 members) =="
docker exec $P-rs vtysh -c "show bgp ipv4 unicast summary" | grep -E "^Neighbor|^10\."

echo "== 3. br1's choice for fastweb's prefix: peering (300) beats transit (200) =="
docker exec $P-br1 vtysh -c "show bgp ipv4 unicast 198.18.1.0/24" | grep -E "^  [0-9]|localpref"

echo "== 4. Customers to the peers, direct over the exchange =="
docker exec $P-milan traceroute -n -s 192.0.2.1 198.18.1.1
pings

echo "== 5. Leak test: fastweb starts sending its transit routes to the exchange =="
docker exec $P-fastweb vtysh -c "conf t" -c "route-map OWN-ONLY permit 20" -c "end" -c "clear bgp ipv4 unicast 10.200.0.1 soft out"
for i in $(seq 1 60); do
  docker exec $P-br1 vtysh -c "show bgp ipv4 unicast neighbors 10.200.0.1 received-routes" | grep -q "198.51.100.0/24" && break
  sleep 1
done
echo "-- received by br1 from the route server"
docker exec $P-br1 vtysh -c "show bgp ipv4 unicast neighbors 10.200.0.1 received-routes" | grep -E "[0-9]/[0-9]+ |Total"
echo "-- accepted by br1"
docker exec $P-br1 vtysh -c "show bgp ipv4 unicast neighbors 10.200.0.1 routes" | grep -E "[0-9]/[0-9]+ |Total"
br1_via 198.51.100.0/24 10.100.1.1 && echo "  internet traffic still via Arelion: leak BLOCKED" || echo "  LEAK ACCEPTED"
docker exec $P-fastweb vtysh -c "conf t" -c "no route-map OWN-ONLY permit 20" -c "end" -c "clear bgp ipv4 unicast 10.200.0.1 soft out"
echo "  fastweb fixed"

echo "== 6. Failover: exchange session down, traffic falls back to transit =="
docker exec $P-br1 vtysh -c "conf t" -c "router bgp 65000" -c "neighbor 10.200.0.1 shutdown"
wait_br1 198.18.1.0/24 10.100.1.1 "Arelion (transit)"
docker exec $P-milan traceroute -n -s 192.0.2.1 198.18.1.1
pings
docker exec $P-br1 vtysh -c "conf t" -c "router bgp 65000" -c "no neighbor 10.200.0.1 shutdown"
wait_br1 198.18.1.0/24 10.200.0.11 "MIX (fastweb)"
echo "Exchange session restored."
