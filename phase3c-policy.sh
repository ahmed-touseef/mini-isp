#!/usr/bin/env bash
# Phase 3c: routing policy on the border routers, applied live (no restart). Run with sudo.
set -u
cd "$(dirname "$0")"
P=clab-miniiliad

apply() {  # node; config commands on stdin
  local args=(-c "conf t") line
  while IFS= read -r line; do [ -n "$line" ] && args+=(-c "$line"); done
  docker exec $P-$1 vtysh "${args[@]}"
}

filters() {  # inbound protection, same on both borders
cat <<'CMD'
ip prefix-list BOGONS seq 5 permit 0.0.0.0/8 le 32
ip prefix-list BOGONS seq 10 permit 10.0.0.0/8 le 32
ip prefix-list BOGONS seq 15 permit 100.64.0.0/10 le 32
ip prefix-list BOGONS seq 20 permit 127.0.0.0/8 le 32
ip prefix-list BOGONS seq 25 permit 169.254.0.0/16 le 32
ip prefix-list BOGONS seq 30 permit 172.16.0.0/12 le 32
ip prefix-list BOGONS seq 35 permit 192.168.0.0/16 le 32
ip prefix-list BOGONS seq 40 permit 224.0.0.0/3 le 32
ip prefix-list BOGONS seq 45 permit 0.0.0.0/0
ip prefix-list BOGONS seq 50 permit 0.0.0.0/0 ge 25
ip prefix-list OUR-SPACE seq 5 permit 192.0.2.0/24 le 32
route-map UPSTREAM-IN deny 5
 match ip address prefix-list BOGONS
exit
route-map UPSTREAM-IN deny 6
 match ip address prefix-list OUR-SPACE
exit
CMD
}

echo "== br1: Arelion preferred (local preference 200) =="
{ filters; cat <<'CMD'
route-map UPSTREAM-IN permit 10
 set local-preference 200
exit
router bgp 65000
address-family ipv4 unicast
neighbor 10.100.1.1 soft-reconfiguration inbound
neighbor 10.100.1.1 maximum-prefix 100 80 restart 5
CMD
} | apply br1

echo "== br2: Cogent as backup (local preference 100, prepend outbound) =="
{ filters; cat <<'CMD'
route-map UPSTREAM-IN permit 10
 set local-preference 100
exit
route-map UPSTREAM-OUT permit 10
 set as-path prepend 65000 65000
exit
router bgp 65000
address-family ipv4 unicast
neighbor 10.100.2.1 soft-reconfiguration inbound
neighbor 10.100.2.1 maximum-prefix 100 80 restart 5
CMD
} | apply br2

echo "== Soft refresh: re-evaluate routes without dropping sessions =="
docker exec $P-br1 vtysh -c "clear bgp ipv4 unicast 10.100.1.1 soft"
docker exec $P-br2 vtysh -c "clear bgp ipv4 unicast 10.100.2.1 soft"

for b in br1 br2; do
  docker exec $P-$b vtysh -c "show running-config" | sed '1,/^Current configuration:/d' > configs/$b.conf
  echo "Saved configs/$b.conf"
done
