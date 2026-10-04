#!/usr/bin/env bash
# Phase 3c checks: routing policy at the edge. Run with sudo.
P=clab-miniiliad
CORE="milan rome naples bologna"
CUST="milan:192.0.2.1 rome:192.0.2.65 naples:192.0.2.129 bologna:192.0.2.193"

all_via() { for r in $CORE; do docker exec $P-$r vtysh -c "show ip route 198.51.100.0/24" | grep -qF "$1" || return 1; done; }
wait_all_via() {  # next_hop label
  for i in $(seq 1 60); do all_via "$1" && { echo "  all core routers exit via $2 after ${i}s"; return; }; sleep 1; done
  echo "  TIMEOUT waiting for $2"
}
exits() {
  for r in $CORE; do
    nh=$(docker exec $P-$r vtysh -c "show ip route 198.51.100.0/24" | grep -m1 -o "10\.255\.0\.[0-9]*")
    case $nh in 10.255.0.5) ex="br1 -> Arelion";; 10.255.0.6) ex="br2 -> Cogent";; *) ex="?";; esac
    printf "  %-8s next hop %-11s %s\n" $r "$nh" "$ex"
  done
}
pings() {
  for c in $CUST; do r=${c%%:*}; s=${c#*:}
    docker exec $P-$r ping -c2 -W1 -I $s 198.51.100.1 >/dev/null && echo "  OK   $r" || echo "  FAIL $r"
  done
}

echo "== 1. Outbound: local preference sends every router to Arelion =="
wait_all_via 10.255.0.5 "br1 (Arelion)"
exits
echo "-- br2's view of 198.51.100.0/24 (its own Cogent path loses on local pref)"
docker exec $P-br2 vtysh -c "show bgp ipv4 unicast 198.51.100.0/24" | grep -E "^  [0-9]|localpref"

echo "== 2. Inbound: prepending pulls return traffic onto Arelion =="
for i in $(seq 1 60); do
  docker exec $P-internet vtysh -c "show bgp ipv4 unicast 192.0.2.0/24" | grep -q "65102 65000 65000 65000" && break
  sleep 1
done
docker exec $P-internet vtysh -c "show bgp ipv4 unicast 192.0.2.0/24" | grep -E "^  [0-9]|valid"

echo "== 3. Protection: the internet announces junk =="
docker exec $P-internet vtysh -c "conf t" \
  -c "ip route 10.10.10.0/24 blackhole" -c "ip route 192.0.2.128/25 blackhole" -c "ip route 203.0.113.240/28 blackhole" \
  -c "router bgp 65200" -c "address-family ipv4 unicast" \
  -c "network 10.10.10.0/24" -c "network 192.0.2.128/25" -c "network 203.0.113.240/28"
for i in $(seq 1 60); do
  docker exec $P-br1 vtysh -c "show bgp ipv4 unicast neighbors 10.100.1.1 received-routes" | grep -q "10.10.10.0/24" && break
  sleep 1
done
echo "-- received by br1 from Arelion"
docker exec $P-br1 vtysh -c "show bgp ipv4 unicast neighbors 10.100.1.1 received-routes" | grep -E "[0-9]/[0-9]+ |Total"
echo "-- accepted by br1"
docker exec $P-br1 vtysh -c "show bgp ipv4 unicast neighbors 10.100.1.1 routes" | grep -E "[0-9]/[0-9]+ |Total"
echo "-- verdict"
for n in 10.10.10.0/24 192.0.2.128/25 203.0.113.240/28; do
  docker exec $P-br1 vtysh -c "show bgp ipv4 unicast $n" | grep -q "not in table" && echo "  BLOCKED $n" || echo "  LEAKED  $n"
done
docker exec $P-internet vtysh -c "conf t" -c "router bgp 65200" -c "address-family ipv4 unicast" \
  -c "no network 10.10.10.0/24" -c "no network 192.0.2.128/25" -c "no network 203.0.113.240/28" -c "exit" -c "exit" \
  -c "no ip route 10.10.10.0/24 blackhole" -c "no ip route 192.0.2.128/25 blackhole" -c "no ip route 203.0.113.240/28 blackhole"
echo "  junk announcements removed"
sleep 3

echo "== 4. Customers reach the internet =="
pings

echo "== 5. Failover: lose Arelion, everything moves to Cogent =="
docker exec $P-br1 vtysh -c "conf t" -c "router bgp 65000" -c "neighbor 10.100.1.1 shutdown"
wait_all_via 10.255.0.6 "br2 (Cogent)"
pings
docker exec $P-br1 vtysh -c "conf t" -c "router bgp 65000" -c "no neighbor 10.100.1.1 shutdown"
wait_all_via 10.255.0.5 "br1 (Arelion)"
echo "Arelion session restored."
