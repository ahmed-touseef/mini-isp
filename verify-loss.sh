#!/usr/bin/env bash
# Measures traffic loss when the milan<->rome link fails. Run with sudo.
#   ./verify-loss.sh down     interface goes down (cable pulled)
#   ./verify-loss.sh silent   packets dropped, interface stays UP
P=clab-miniiliad
MODE=${1:-down}
via_eth() { docker exec $P-milan ip route get 10.255.0.2 | grep -q "dev $1"; }
for i in $(seq 1 60); do via_eth eth1 && break; sleep 1; done

echo "== Mode: $MODE. One ping every 10 ms, milan LAN -> rome LAN, link breaks after 2 s =="
docker exec $P-milan ping -q -i 0.01 -c 600 -W 1 -I 192.0.2.1 192.0.2.65 > /tmp/loss.txt 2>&1 &
PING=$!
sleep 2
if [ "$MODE" = silent ]; then
  docker exec $P-milan tc qdisc add dev eth1 root netem loss 100%
  docker exec $P-rome  tc qdisc add dev eth1 root netem loss 100%
else
  docker exec $P-milan ip link set eth1 down
fi
wait $PING
tail -2 /tmp/loss.txt
tx=$(grep -oE '[0-9]+ packets transmitted' /tmp/loss.txt | awk '{print $1}')
rx=$(grep -oE '[0-9]+ (packets )?received' /tmp/loss.txt | awk '{print $1}')
lost=$(( tx - rx ))
echo "  RESULT ($MODE): lost $lost packets, about $(( lost * 10 )) ms of outage"

echo "== Repair =="
if [ "$MODE" = silent ]; then
  docker exec $P-milan tc qdisc del dev eth1 root
  docker exec $P-rome  tc qdisc del dev eth1 root
else
  docker exec $P-milan ip link set eth1 up
fi
for i in $(seq 1 60); do via_eth eth1 && { echo "  back via eth1 after ${i}s"; break; }; sleep 1; done
