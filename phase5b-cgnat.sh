#!/usr/bin/env bash
# Phase 5b: CGNAT on the BNG, applied live and saved in the topology. Run with sudo.
set -eu
cd "$(dirname "$0")"
P=clab-miniiliad

cat > configs/cgnat.nft <<'NFT'
# CGNAT: homes in 100.64.0.0/24 (RFC 6598) share the public pool 192.0.2.33 to 192.0.2.46
table ip cgnat {
  chain postrouting {
    type nat hook postrouting priority srcnat; policy accept;
    ip saddr 100.64.0.0/24 oifname "eth1" snat to 192.0.2.33-192.0.2.46 persistent
  }
}
NFT
chown --reference=configs/bng.conf configs/cgnat.nft

# Persist: mount the rule file into the BNG and load it at deploy
if ! grep -q cgnat.nft mini-iliad.clab.yml; then
  sed -i 's|configs/bng.conf:/etc/frr/frr.conf, |configs/bng.conf:/etc/frr/frr.conf, configs/cgnat.nft:/etc/cgnat.nft, |' mini-iliad.clab.yml
  sed -i 's|^\( *\)- apk add --no-cache -q dnsmasq nftables$|\1- apk add --no-cache -q dnsmasq nftables conntrack-tools\n\1- nft -f /etc/cgnat.nft|' mini-iliad.clab.yml
fi

# Apply live on the running BNG
docker exec $P-bng apk add --no-cache -q conntrack-tools
docker cp configs/cgnat.nft $P-bng:/etc/cgnat.nft
docker exec $P-bng sh -c 'nft delete table ip cgnat 2>/dev/null; nft -f /etc/cgnat.nft'
echo "CGNAT active on the BNG"
