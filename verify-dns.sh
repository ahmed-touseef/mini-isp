#!/usr/bin/env bash
# Phase 5c checks: anycast DNS. Run with sudo.
P=clab-miniiliad
whoami_from() { docker exec $P-$1 nslookup whoami.lab 192.0.2.53 2>/dev/null | grep -oE "10\.255\.0\.[89]" | tail -1; }

echo "== Waiting for both resolvers to announce 192.0.2.53 =="
for i in $(seq 1 90); do
  n=$(docker exec $P-rr1 vtysh -c "show bgp ipv4 unicast 192.0.2.53/32" 2>/dev/null | grep -cE "from 10\.255\.0\.[89] ")
  [ "$n" -ge 2 ] && { echo "  both announcements seen after ${i}s"; break; }
  sleep 1
done
docker exec $P-rr1 vtysh -c "show bgp ipv4 unicast 192.0.2.53/32" | grep -E "from|best"

echo "== home1 got the resolver via DHCP =="
docker exec $P-home1 cat /etc/resolv.conf

echo "== Name resolution from home1 =="
for n in web.internet.lab fastweb.lab netflix.lab; do
  a=$(docker exec $P-home1 nslookup $n 2>/dev/null | grep -A1 "Name:" | grep -oE "Address:? *[0-9.]+" | grep -oE "[0-9.]+$")
  echo "  $n -> ${a:-FAILED}"
done
docker exec $P-home1 ping -c2 -W1 web.internet.lab >/dev/null && echo "  OK   ping web.internet.lab by name" || echo "  FAIL ping web.internet.lab by name"

echo "== Anycast: same address, nearest server answers =="
echo "  home1 (behind milan) is answered by $(whoami_from home1)   (expect 10.255.0.8, dns-mi)"
echo "  naples router        is answered by $(whoami_from naples)  (expect 10.255.0.9, dns-na)"

echo "== Failover: dns-mi loses its link =="
now_ms() { echo $(( $(date +%s%N) / 1000000 )); }
docker exec $P-dns-mi ip link set eth1 down
start=$(now_ms)
for i in $(seq 1 300); do
  docker exec $P-bng vtysh -c "show ip route 192.0.2.53/32" | grep -q "10.255.0.9" && { echo "  BNG route switched to dns-na after $(( $(now_ms) - start )) ms"; break; }
  sleep 0.1
done
echo "  home1 is now answered by $(whoami_from home1)   (expect 10.255.0.9)"
docker exec $P-dns-mi ip link set eth1 up
for i in $(seq 1 60); do
  [ "$(whoami_from home1)" = "10.255.0.8" ] && { echo "  dns-mi back, home1 answered by it again after ${i}s"; break; }
  sleep 1
done
