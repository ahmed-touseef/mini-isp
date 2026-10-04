#!/usr/bin/env bash
# Phase 5a: access network. BNG with DHCP, an access switch (OLT) and two homes. Edits files only.
set -eu
cd "$(dirname "$0")"
if [ -f configs/bng.conf ]; then echo "Phase 5a already applied"; exit 0; fi
B="configs/daemons:/etc/frr/daemons, configs/vtysh.conf:/etc/frr/vtysh.conf"

# 1. Topology: new nodes before "links:", new links at the end
cat > /tmp/access-nodes.yml <<YML
    bng:
      binds: [configs/bng.conf:/etc/frr/frr.conf, $B]
      exec:
        - sysctl -w net.ipv4.ip_forward=1
        - sysctl -w net.mpls.conf.eth1.input=1
        - apk add --no-cache -q dnsmasq nftables
        - ip addr add 100.64.0.1/24 dev eth2
        - dnsmasq --interface=eth2 --bind-interfaces --port=0 --dhcp-range=100.64.0.10,100.64.0.200,255.255.255.0,1h --dhcp-option=option:router,100.64.0.1 --dhcp-leasefile=/tmp/dnsmasq.leases
    olt:
      exec:
        - ip link add br0 type bridge
        - ip link set br0 up
        - ip link set eth1 master br0
        - ip link set eth2 master br0
        - ip link set eth3 master br0
    home1:
      exec:
        - ip route del default
        - udhcpc -i eth1 -n -q -t 20 -T 2
    home2:
      exec:
        - ip route del default
        - udhcpc -i eth1 -n -q -t 20 -T 2

YML
awk '/^  links:/{while((getline l < "/tmp/access-nodes.yml")>0) print l} {print}' mini-iliad.clab.yml > /tmp/clab.yml
mv /tmp/clab.yml mini-iliad.clab.yml
cat >> mini-iliad.clab.yml <<'YML'
    - endpoints: ["milan:eth5", "bng:eth1"]            # 10.0.0.16/31
    - endpoints: ["bng:eth2", "olt:eth1"]              # access network 100.64.0.0/24
    - endpoints: ["home1:eth1", "olt:eth2"]
    - endpoints: ["home2:eth1", "olt:eth3"]
YML
sed -i 's/for i in eth1 eth2 eth3 eth4;/for i in eth1 eth2 eth3 eth4 eth5;/' mini-iliad.clab.yml

# 2. Milan: link to the BNG
sed -i '/^end$/d' configs/milan.conf
cat >> configs/milan.conf <<'CFG'
interface eth5
 description BNG
 ip address 10.0.0.16/31
 ip router isis CORE
 isis network point-to-point
 isis bfd
 isis bfd profile FAST
exit
!
CFG

# 3. Route reflectors: the BNG is a new client
sed -i '/neighbor 10.255.0.6 peer-group CLIENTS/a\ neighbor 10.255.0.7 peer-group CLIENTS' configs/rr1.conf configs/rr2.conf

# 4. The BNG
cat > configs/bng.conf <<'CFG'
frr defaults traditional
hostname bng
service integrated-vtysh-config
no zebra nexthop kernel enable
!
bfd
 profile FAST
  detect-multiplier 3
  receive-interval 100
  transmit-interval 100
 exit
exit
!
interface eth1
 description CORE-MILAN
 ip address 10.0.0.17/31
 ip router isis CORE
 isis network point-to-point
 isis bfd
 isis bfd profile FAST
exit
!
interface eth2
 description ACCESS-OLT
exit
!
interface lo
 ip address 10.255.0.7/32
 ip router isis CORE
 isis passive
exit
!
ip route 192.0.2.32/28 blackhole
!
router isis CORE
 is-type level-2-only
 net 49.0001.0102.5500.0007.00
 lsp-gen-interval 1
 spf-interval 1
 segment-routing on
 segment-routing global-block 16000 23999
 segment-routing prefix 10.255.0.7/32 index 7
exit
!
router bgp 65000
 bgp router-id 10.255.0.7
 neighbor RR peer-group
 neighbor RR remote-as 65000
 neighbor RR update-source 10.255.0.7
 neighbor RR timers connect 5
 neighbor 10.255.0.11 peer-group RR
 neighbor 10.255.0.12 peer-group RR
 !
 address-family ipv4 unicast
  network 192.0.2.32/28
  neighbor RR activate
 exit-address-family
exit
!
CFG

echo "Phase 5a files written. Next: sudo containerlab deploy -t mini-iliad.clab.yml --reconfigure"
