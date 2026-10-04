#!/usr/bin/env bash
# Mini Iliad Phase 1: install Docker + containerlab (only if missing). Run with sudo.
set -euo pipefail

avail_mb=$(free -m | awk '/^Mem:/ {print $7}')
echo "Available RAM: ${avail_mb} MB"
if [ "$avail_mb" -lt 1500 ]; then
  echo "Less than 1.5 GB free. Stopping to protect the websites on this box."; exit 1
fi

if ! command -v docker >/dev/null; then
  curl -fsSL https://get.docker.com | sh
fi
if ! command -v containerlab >/dev/null; then
  bash -c "$(curl -sL https://get.containerlab.dev)"
fi

docker --version
containerlab version
modprobe -a mpls_router mpls_iptunnel sch_netem
echo "Setup done. Next: sudo containerlab deploy -t mini-iliad.clab.yml"
