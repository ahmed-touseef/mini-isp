#!/usr/bin/env bash
# Phase 5d checks, server side. Run with sudo.
P=clab-miniiliad
echo "== WireGuard on the BNG (private key hidden) =="
docker exec $P-bng wg show wg0 | grep -v "private key"
docker exec $P-bng ip -br addr show wg0
echo "== CGNAT covers 100.64.0.0/16 =="
docker exec $P-bng nft list table ip cgnat | grep snat
echo "== UDP 51820 published on the host =="
docker port $P-bng
