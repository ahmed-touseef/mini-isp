#!/usr/bin/env bash
# Mini Iliad core checks (IS-IS). Run with sudo.
P=clab-miniiliad
R="milan rome naples bologna"

echo "== Waiting for IS-IS to converge (expect 8 adjacencies Up) =="
for i in $(seq 1 30); do
  total=0
  for r in $R; do
    n=$(docker exec $P-$r vtysh -c "show isis neighbor" 2>/dev/null | grep -cw Up)
    total=$((total + n))
  done
  echo "  $total/8 Up"
  [ "$total" -eq 8 ] && break
  sleep 2
done
sleep 5

echo "== IS-IS neighbors =="
for r in $R; do echo "-- $r"; docker exec $P-$r vtysh -c "show isis neighbor"; done

echo "== Leftover OSPF routes on milan (expect none) =="
docker exec $P-milan vtysh -c "show ip route ospf"

echo "== Loopback reachability from milan =="
for ip in 10.255.0.2 10.255.0.3 10.255.0.4; do
  docker exec $P-milan ping -c2 -W1 -I 10.255.0.1 $ip >/dev/null && echo "OK   $ip" || echo "FAIL $ip"
done

echo "== Failover test: cut milan<->rome =="
docker exec $P-milan ip link set eth1 down
sleep 12
docker exec $P-milan vtysh -c "show ip route 10.255.0.2"
docker exec $P-milan traceroute -n -s 10.255.0.1 10.255.0.2
docker exec $P-milan ip link set eth1 up
echo "Link restored."
