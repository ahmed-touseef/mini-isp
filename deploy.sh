#!/usr/bin/env bash
# Render configs from NetBox and push them to running routers with frr-reload (only the differences).
#   ./deploy.sh plan  <device> [device ...]   render and show what would change (nothing applied)
#   ./deploy.sh apply <device> [device ...]   render and apply the differences live
# Run as your normal user; sudo is used for the docker steps.
set -eu
cd "$(dirname "$0")"
MODE=${1:-}; shift || true
[ "$MODE" = plan ] || [ "$MODE" = apply ] || { echo "usage: $0 plan|apply <device> [device ...]"; exit 1; }
[ $# -gt 0 ] || { echo "name at least one device"; exit 1; }

python3 netbox/render.py
FILES=$(printf 'generated/%s.conf ' "$@")
echo "== Config file changes =="
git --no-pager diff -U0 -- $FILES | grep -E '^(\+\+\+|[+-][^+-])' || echo "  (no file changes)"

for d in "$@"; do
  echo "== $d: changes frr-reload would make on the running router =="
  sudo docker exec clab-miniiliad-$d /usr/lib/frr/frr-reload.py --test --stdout /etc/frr/frr.conf 2>&1 | grep -vE '^\s*$' | head -40
  if [ "$MODE" = apply ]; then
    echo "== $d: applying =="
    sudo docker exec clab-miniiliad-$d /usr/lib/frr/frr-reload.py --reload --stdout /etc/frr/frr.conf 2>&1 | tail -3
  fi
done
