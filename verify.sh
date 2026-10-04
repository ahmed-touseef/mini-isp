#!/usr/bin/env bash
# Mini Iliad core checks (IS-IS). Run with sudo.
P=clab-miniiliad
R="milan rome naples bologna"
LOOPS="10.255.0.2 10.255.0.3 10.255.0.4"

routes_ready() {
  local t; t=$(docker exec $P-milan vtysh -c "show ip route isis" 2>/dev/null)
  for ip in $LOOPS; do echo "$t" | grep -qE "^I>\* +$ip/32" || return 1; done
}

echo "== Waiting for milan to install IS-IS routes to all loopbacks =="
for i in $(seq 1 90); do
  routes_ready && { echo "  routes installed after ${i}s"; break; }
  sleep 1
done

echo "== IS-IS neighbors =="
for r in $R; do echo "-- $r"; docker exec $P-$r vtysh -c "show isis neighbor"; done

echo "== Leftover OSPF routes on milan (expect none) =="
docker exec $P-milan vtysh -c "show ip route ospf"

echo "== Loopback reachability from milan =="
for ip in $LOOPS; do
  docker exec $P-milan ping -c2 -W1 -I 10.255.0.1 $ip >/dev/null && echo "OK   $ip" || echo "FAIL $ip"
done

echo "== Failover test: cut milan<->rome =="
docker exec $P-milan ip link set eth1 down
for i in $(seq 1 30); do
  docker exec $P-milan vtysh -c "show ip route 10.255.0.2" | grep -q "via eth2" && { echo "  rerouted after ${i}s"; break; }
  sleep 1
done
docker exec $P-milan vtysh -c "show ip route 10.255.0.2"
docker exec $P-milan traceroute -n -s 10.255.0.1 10.255.0.2
docker exec $P-milan ip link set eth1 up
echo "Link restored."
