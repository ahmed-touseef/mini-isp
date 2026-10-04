#!/usr/bin/env bash
# Phase 5d: WireGuard on the BNG so a real home PC becomes a subscriber.
# Keys live in secrets/, which is never committed.
set -eu
cd "$(dirname "$0")"
if [ -f secrets/wg0.conf ]; then echo "Phase 5d already applied"; exit 0; fi

PUB=$(ip -4 route get 1.1.1.1 | awk '{for(i=1;i<=NF;i++) if($i=="src") print $(i+1)}')
echo "Server public IP: $PUB"

# 1. Keys and configs (owner only)
mkdir -p secrets && chmod 700 secrets
grep -qx "secrets/" .gitignore || echo "secrets/" >> .gitignore
umask 077
wg genkey | tee secrets/server.key | wg pubkey > secrets/server.pub
wg genkey | tee secrets/client.key | wg pubkey > secrets/client.pub

cat > secrets/wg0.conf <<CFG
[Interface]
PrivateKey = $(cat secrets/server.key)
ListenPort = 51820

[Peer]
# Touseef's home PC
PublicKey = $(cat secrets/client.pub)
AllowedIPs = 100.64.1.2/32
CFG

cat > secrets/home-pc.conf <<CFG
[Interface]
PrivateKey = $(cat secrets/client.key)
Address = 100.64.1.2/32

[Peer]
PublicKey = $(cat secrets/server.pub)
Endpoint = $PUB:51820
AllowedIPs = 100.64.1.1/32, 192.0.2.0/24, 198.51.100.0/24, 203.0.113.0/24, 198.18.0.0/15
PersistentKeepalive = 25
CFG
umask 022

# 2. CGNAT now covers fibre homes (100.64.0.x) and tunnel customers (100.64.1.x)
sed -i 's|100\.64\.0\.0/24|100.64.0.0/16|g' configs/cgnat.nft

# 3. BNG: mount the WireGuard config, publish UDP 51820, bring up wg0 at deploy
if ! grep -q wg0.conf mini-iliad.clab.yml; then
sed -i 's|configs/bng.conf:/etc/frr/frr.conf, |configs/bng.conf:/etc/frr/frr.conf, secrets/wg0.conf:/etc/wireguard/wg0.conf, |' mini-iliad.clab.yml
sed -i 's|^\(      binds: \[configs/bng.conf:.*\]\)$|\1\n      ports: ["51820:51820/udp"]|' mini-iliad.clab.yml
sed -i 's|dnsmasq nftables conntrack-tools$|dnsmasq nftables conntrack-tools wireguard-tools|' mini-iliad.clab.yml
sed -i 's|^\( *\)- nft -f /etc/cgnat.nft$|&\n\1- ip link add wg0 type wireguard\n\1- wg setconf wg0 /etc/wireguard/wg0.conf\n\1- ip addr add 100.64.1.1/24 dev wg0\n\1- ip link set wg0 up|' mini-iliad.clab.yml

fi

echo "Phase 5d files written. Next: sudo containerlab deploy -t mini-iliad.clab.yml --reconfigure"
