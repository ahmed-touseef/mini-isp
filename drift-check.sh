#!/usr/bin/env bash
# Compares every running router with its generated config. Run as your normal user.
# Exit code = number of routers that drifted (0 means NetBox, Git and the network agree).
cd "$(dirname "$0")"
drift=0
for f in generated/*.conf; do
  d=$(basename "$f" .conf)
  out=$(sudo docker exec clab-miniiliad-$d /usr/lib/frr/frr-reload.py --test --stdout /etc/frr/frr.conf 2>&1 \
        | grep -vE 'INFO:|^\s*$|^=+$|Lines To (Delete|Add)|^ipv6 forwarding$')
  if [ -z "$out" ]; then echo "  clean  $d"; else echo "  DRIFT  $d:"; echo "$out" | sed 's/^/      /'; drift=$((drift + 1)); fi
done
echo "== $drift router(s) drifted =="
exit $drift
