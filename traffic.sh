#!/usr/bin/env bash
# Demo traffic for the dashboards. Run with sudo.
#   ./traffic.sh start   20 Mbit/s Milan LAN to Rome LAN (iperf3 UDP), about 1 Mbit/s home1 to the internet
#   ./traffic.sh stop
P=clab-miniiliad
case "${1:-}" in
start)
  for r in milan rome; do docker exec $P-$r sh -c 'command -v iperf3 >/dev/null || apk add --no-cache -q iperf3'; done
  docker exec $P-rome sh -c 'pkill iperf3; iperf3 -s -D -B 192.0.2.65'
  docker exec -d $P-milan iperf3 -c 192.0.2.65 -B 192.0.2.1 -u -b 20M -l 1200 -t 3600
  docker exec -d $P-home1 ping -q -s 1200 -i 0.01 198.51.100.1
  echo "traffic started: 20 Mbit/s Milan LAN to Rome LAN, about 1 Mbit/s home1 to the internet" ;;
stop)
  docker exec $P-milan pkill iperf3; docker exec $P-rome pkill iperf3; docker exec $P-home1 pkill ping
  echo "traffic stopped" ;;
*) echo "usage: $0 start|stop"; exit 1 ;;
esac
