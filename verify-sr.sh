#!/usr/bin/env bash
# Phase 4a checks: Segment Routing MPLS on IS-IS. Run with sudo.
P=clab-miniiliad
SR="milan rome naples bologna br1 br2 rr1 rr2"

echo "== Waiting for SIDs on milan and BGP over MPLS to the naples pool =="
for i in $(seq 1 90); do
  n=$(docker exec $P-milan vtysh -c "show mpls table" 2>/dev/null | grep -oE "^ *160[0-9]{2}" | tr -d ' ' | sort -u | wc -l)
  [ "$n" -ge 7 ] && docker exec $P-milan ip route show 192.0.2.128/26 | grep -q "encap mpls" && { echo "  ready after ${i}s"; break; }
  sleep 1
done

echo "== Dead label entries per router (expect 0 everywhere) =="
for r in $SR; do printf "  %-8s %s\n" $r "$(docker exec $P-$r ip -f mpls route | grep -c dead)"; done

echo "== milan's kernel label table =="
docker exec $P-milan ip -f mpls route

echo "== milan to the naples pool (expect encap mpls 16003 single path via rome) =="
docker exec $P-milan ip route show 192.0.2.128/26

echo "== rome to the internet via br1 (expect encap mpls 16005) =="
docker exec $P-rome ip route show 198.51.100.0/24

echo "== Traffic over MPLS =="
docker exec $P-milan ping -c2 -W1 -I 192.0.2.1 192.0.2.129 >/dev/null && echo "  OK   milan pool -> naples pool" || echo "  FAIL milan pool -> naples pool"
for c in milan:192.0.2.1 rome:192.0.2.65 naples:192.0.2.129 bologna:192.0.2.193; do
  r=${c%%:*}; s=${c#*:}
  docker exec $P-$r ping -c2 -W1 -I $s 198.51.100.1 >/dev/null && echo "  OK   $r -> internet" || echo "  FAIL $r -> internet"
done
