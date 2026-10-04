#!/usr/bin/env bash
# Silent failure test: all packets on milan<->rome are dropped while both interfaces stay UP. Run with sudo.
P=clab-miniiliad
via_eth() { docker exec $P-milan ip route get 10.255.0.2 | grep -q "dev $1"; }
now_ms() { echo $(( $(date +%s%N) / 1000000 )); }

echo "== Before: milan reaches rome via eth1 =="
for i in $(seq 1 60); do via_eth eth1 && break; sleep 1; done
docker exec $P-milan ip route get 10.255.0.2 | head -1

echo "== BFD sessions on milan =="
docker exec $P-milan vtysh -c "show bfd peers brief"

echo "== Silent failure: drop every packet on milan<->rome, interfaces stay UP =="
docker exec $P-milan tc qdisc add dev eth1 root netem loss 100%
docker exec $P-rome  tc qdisc add dev eth1 root netem loss 100%
docker exec $P-milan ip -br link show eth1
start=$(now_ms); detected=""
while [ $(( $(now_ms) - start )) -lt 60000 ]; do
  via_eth eth2 && { detected=$(( $(now_ms) - start )); break; }
  sleep 0.05
done
[ -n "$detected" ] && echo "  milan rerouted via bologna after ${detected} ms" || echo "  NOT rerouted within 60 s"
docker exec $P-milan ip route get 10.255.0.2 | head -1

echo "== Repair the link =="
docker exec $P-milan tc qdisc del dev eth1 root
docker exec $P-rome  tc qdisc del dev eth1 root
for i in $(seq 1 60); do via_eth eth1 && { echo "  back via eth1 after ${i}s"; break; }; sleep 1; done
