#!/bin/sh
# Minimal udhcpc hook. Writes resolv.conf in place: Docker bind-mounts it, so the stock script's rename fails.
case "$1" in
  deconfig)
    ip -4 addr flush dev "$interface"; ip link set "$interface" up ;;
  bound|renew)
    ip -4 addr flush dev "$interface"
    ip addr add "$ip/$mask" dev "$interface"
    [ -n "$router" ] && ip route replace default via "${router%% *}" dev "$interface"
    if [ -n "$dns" ]; then
      : > /etc/resolv.conf
      for s in $dns; do echo "nameserver $s" >> /etc/resolv.conf; done
    fi ;;
esac
