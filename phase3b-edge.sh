#!/usr/bin/env bash
# Phase 3b: internet edge. Two border routers, two upstreams, a fake internet. Edits files only.
set -eu
cd "$(dirname "$0")"
if [ -f configs/br1.conf ]; then echo "Phase 3b already applied"; exit 0; fi

# 1. Topology
cat > mini-iliad.clab.yml <<'YML'
# Mini Iliad: IS-IS core, iBGP route reflectors, internet edge with two upstreams (FRR)
name: miniiliad

mgmt:
  network: miniiliad-mgmt
  ipv4-subnet: 172.30.30.0/24

topology:
  defaults:
    kind: linux
    image: quay.io/frrouting/frr:10.2.1
  nodes:
    milan:
      binds: [configs/milan.conf:/etc/frr/frr.conf, configs/daemons:/etc/frr/daemons, configs/vtysh.conf:/etc/frr/vtysh.conf]
      exec:
        - sysctl -w net.ipv4.ip_forward=1
        - ip link add cust0 type dummy
        - ip link set cust0 up
        - ip addr add 192.0.2.1/26 dev cust0
    rome:
      binds: [configs/rome.conf:/etc/frr/frr.conf, configs/daemons:/etc/frr/daemons, configs/vtysh.conf:/etc/frr/vtysh.conf]
      exec:
        - sysctl -w net.ipv4.ip_forward=1
        - ip link add cust0 type dummy
        - ip link set cust0 up
        - ip addr add 192.0.2.65/26 dev cust0
    naples:
      binds: [configs/naples.conf:/etc/frr/frr.conf, configs/daemons:/etc/frr/daemons, configs/vtysh.conf:/etc/frr/vtysh.conf]
      exec:
        - sysctl -w net.ipv4.ip_forward=1
        - ip link add cust0 type dummy
        - ip link set cust0 up
        - ip addr add 192.0.2.129/26 dev cust0
    bologna:
      binds: [configs/bologna.conf:/etc/frr/frr.conf, configs/daemons:/etc/frr/daemons, configs/vtysh.conf:/etc/frr/vtysh.conf]
      exec:
        - sysctl -w net.ipv4.ip_forward=1
        - ip link add cust0 type dummy
        - ip link set cust0 up
        - ip addr add 192.0.2.193/26 dev cust0
    rr1:
      binds: [configs/rr1.conf:/etc/frr/frr.conf, configs/daemons:/etc/frr/daemons, configs/vtysh.conf:/etc/frr/vtysh.conf]
      exec:
        - sysctl -w net.ipv4.ip_forward=1
    rr2:
      binds: [configs/rr2.conf:/etc/frr/frr.conf, configs/daemons:/etc/frr/daemons, configs/vtysh.conf:/etc/frr/vtysh.conf]
      exec:
        - sysctl -w net.ipv4.ip_forward=1
    br1:
      binds: [configs/br1.conf:/etc/frr/frr.conf, configs/daemons:/etc/frr/daemons, configs/vtysh.conf:/etc/frr/vtysh.conf]
      exec:
        - sysctl -w net.ipv4.ip_forward=1
    br2:
      binds: [configs/br2.conf:/etc/frr/frr.conf, configs/daemons:/etc/frr/daemons, configs/vtysh.conf:/etc/frr/vtysh.conf]
      exec:
        - sysctl -w net.ipv4.ip_forward=1
    arelion:
      binds: [configs/arelion.conf:/etc/frr/frr.conf, configs/daemons:/etc/frr/daemons, configs/vtysh.conf:/etc/frr/vtysh.conf]
      exec:
        - sysctl -w net.ipv4.ip_forward=1
    cogent:
      binds: [configs/cogent.conf:/etc/frr/frr.conf, configs/daemons:/etc/frr/daemons, configs/vtysh.conf:/etc/frr/vtysh.conf]
      exec:
        - sysctl -w net.ipv4.ip_forward=1
    internet:
      binds: [configs/internet.conf:/etc/frr/frr.conf, configs/daemons:/etc/frr/daemons, configs/vtysh.conf:/etc/frr/vtysh.conf]
      exec:
        - sysctl -w net.ipv4.ip_forward=1
        - ip link add web0 type dummy
        - ip link set web0 up
        - ip addr add 198.51.100.1/24 dev web0
        - ip addr add 203.0.113.1/24 dev web0

  links:
    - endpoints: ["milan:eth1", "rome:eth1"]           # 10.0.0.0/31
    - endpoints: ["rome:eth2", "naples:eth1"]          # 10.0.0.2/31
    - endpoints: ["naples:eth2", "bologna:eth1"]       # 10.0.0.4/31
    - endpoints: ["bologna:eth2", "milan:eth2"]        # 10.0.0.6/31
    - endpoints: ["milan:eth3", "rr1:eth1"]            # 10.0.0.8/31
    - endpoints: ["naples:eth3", "rr2:eth1"]           # 10.0.0.10/31
    - endpoints: ["milan:eth4", "br1:eth1"]            # 10.0.0.12/31
    - endpoints: ["rome:eth3", "br2:eth1"]             # 10.0.0.14/31
    - endpoints: ["br1:eth2", "arelion:eth1"]          # 10.100.1.0/31
    - endpoints: ["br2:eth2", "cogent:eth1"]           # 10.100.2.0/31
    - endpoints: ["arelion:eth2", "internet:eth1"]     # 10.100.3.0/31
    - endpoints: ["cogent:eth2", "internet:eth2"]      # 10.100.4.0/31
YML

# 2. Core links towards the border routers
cat >> configs/milan.conf <<'CFG'
interface eth4
 ip address 10.0.0.12/31
 ip router isis CORE
 isis network point-to-point
exit
!
CFG
cat >> configs/rome.conf <<'CFG'
interface eth3
 ip address 10.0.0.14/31
 ip router isis CORE
 isis network point-to-point
exit
!
CFG

# 3. Route reflectors gain the two border routers as clients
sed -i '/neighbor 10.255.0.4 peer-group CLIENTS/a\ neighbor 10.255.0.5 peer-group CLIENTS\n neighbor 10.255.0.6 peer-group CLIENTS' configs/rr1.conf configs/rr2.conf

# 4. Border routers
border() {  # name id core_ip ext_ip peer_ip peer_as peer_name
  cat > configs/$1.conf <<CFG
frr defaults traditional
hostname $1
service integrated-vtysh-config
!
interface eth1
 ip address $3/31
 ip router isis CORE
 isis network point-to-point
exit
!
interface eth2
 description $7
 ip address $4/31
exit
!
interface lo
 ip address 10.255.0.$2/32
 ip router isis CORE
 isis passive
exit
!
ip route 192.0.2.0/24 blackhole
!
ip prefix-list OUR-PREFIXES seq 10 permit 192.0.2.0/24
!
route-map UPSTREAM-IN permit 10
exit
!
route-map UPSTREAM-OUT permit 10
 match ip address prefix-list OUR-PREFIXES
exit
!
router isis CORE
 is-type level-2-only
 net 49.0001.0102.5500.000$2.00
 lsp-gen-interval 1
 spf-interval 1
exit
!
router bgp 65000
 bgp router-id 10.255.0.$2
 neighbor RR peer-group
 neighbor RR remote-as 65000
 neighbor RR update-source 10.255.0.$2
 neighbor RR timers connect 5
 neighbor 10.255.0.11 peer-group RR
 neighbor 10.255.0.12 peer-group RR
 neighbor $5 remote-as $6
 neighbor $5 description $7
 neighbor $5 timers connect 5
 !
 address-family ipv4 unicast
  network 192.0.2.0/24
  neighbor RR activate
  neighbor RR next-hop-self
  neighbor $5 activate
  neighbor $5 route-map UPSTREAM-IN in
  neighbor $5 route-map UPSTREAM-OUT out
 exit-address-family
exit
!
CFG
}
border br1 5 10.0.0.13 10.100.1.0 10.100.1.1 65101 ARELION
border br2 6 10.0.0.15 10.100.2.0 10.100.2.1 65102 COGENT

# 5. Upstream carriers (simplified: no RFC 8212 policy check)
upstream() {  # name as cust_ip cust_peer net_ip net_peer
  cat > configs/$1.conf <<CFG
frr defaults traditional
hostname $1
service integrated-vtysh-config
!
interface eth1
 ip address $3/31
exit
!
interface eth2
 ip address $5/31
exit
!
router bgp $2
 bgp router-id $3
 no bgp ebgp-requires-policy
 neighbor $4 remote-as 65000
 neighbor $4 timers connect 5
 neighbor $6 remote-as 65200
 neighbor $6 timers connect 5
exit
!
CFG
}
upstream arelion 65101 10.100.1.1 10.100.1.0 10.100.3.0 10.100.3.1
upstream cogent  65102 10.100.2.1 10.100.2.0 10.100.4.0 10.100.4.1

# 6. The internet
cat > configs/internet.conf <<'CFG'
frr defaults traditional
hostname internet
service integrated-vtysh-config
!
interface eth1
 ip address 10.100.3.1/31
exit
!
interface eth2
 ip address 10.100.4.1/31
exit
!
router bgp 65200
 bgp router-id 10.100.3.1
 no bgp ebgp-requires-policy
 neighbor 10.100.3.0 remote-as 65101
 neighbor 10.100.3.0 timers connect 5
 neighbor 10.100.4.0 remote-as 65102
 neighbor 10.100.4.0 timers connect 5
 !
 address-family ipv4 unicast
  network 198.51.100.0/24
  network 203.0.113.0/24
 exit-address-family
exit
!
CFG

echo "Phase 3b files written. Next: sudo containerlab deploy -t mini-iliad.clab.yml --reconfigure"
