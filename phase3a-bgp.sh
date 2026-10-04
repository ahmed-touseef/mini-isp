#!/usr/bin/env bash
# Phase 3a: iBGP core (AS 65000) with two route reflectors. Edits files only.
set -eu
cd "$(dirname "$0")"
if grep -q "router bgp" configs/milan.conf; then echo "Phase 3a already applied"; exit 0; fi

# 1. Topology: rr1 off milan, rr2 off naples, customer LAN (cust0) on each core router
cat > mini-iliad.clab.yml <<'YML'
# Mini Iliad: IS-IS core ring with iBGP route reflectors (FRR)
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

  links:
    - endpoints: ["milan:eth1", "rome:eth1"]       # 10.0.0.0/31
    - endpoints: ["rome:eth2", "naples:eth1"]      # 10.0.0.2/31
    - endpoints: ["naples:eth2", "bologna:eth1"]   # 10.0.0.4/31
    - endpoints: ["bologna:eth2", "milan:eth2"]    # 10.0.0.6/31
    - endpoints: ["milan:eth3", "rr1:eth1"]        # 10.0.0.8/31
    - endpoints: ["naples:eth3", "rr2:eth1"]       # 10.0.0.10/31
YML

# 2. Core routers: remove trailing "end", add BGP (and eth3 towards the RR on milan/naples)
core() {  # name id pool
  sed -i '/^end$/d' configs/$1.conf
  cat >> configs/$1.conf <<CFG
router bgp 65000
 bgp router-id 10.255.0.$2
 neighbor RR peer-group
 neighbor RR remote-as 65000
 neighbor RR update-source 10.255.0.$2
 neighbor RR timers connect 5
 neighbor 10.255.0.11 peer-group RR
 neighbor 10.255.0.12 peer-group RR
 !
 address-family ipv4 unicast
  network $3
  neighbor RR activate
 exit-address-family
exit
!
CFG
}
rr_link() {  # name ip
  cat >> configs/$1.conf <<CFG
interface eth3
 ip address $2/31
 ip router isis CORE
 isis network point-to-point
exit
!
CFG
}
core milan   1 192.0.2.0/26;   rr_link milan  10.0.0.8
core rome    2 192.0.2.64/26
core naples  3 192.0.2.128/26; rr_link naples 10.0.0.10
core bologna 4 192.0.2.192/26

# 3. Route reflectors
rr() {  # name id link_ip other_rr
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
interface lo
 ip address 10.255.0.$2/32
 ip router isis CORE
 isis passive
exit
!
router isis CORE
 is-type level-2-only
 net 49.0001.0102.5500.00$2.00
 lsp-gen-interval 1
 spf-interval 1
 set-overload-bit
exit
!
router bgp 65000
 bgp router-id 10.255.0.$2
 neighbor CLIENTS peer-group
 neighbor CLIENTS remote-as 65000
 neighbor CLIENTS update-source 10.255.0.$2
 neighbor CLIENTS timers connect 5
 neighbor 10.255.0.1 peer-group CLIENTS
 neighbor 10.255.0.2 peer-group CLIENTS
 neighbor 10.255.0.3 peer-group CLIENTS
 neighbor 10.255.0.4 peer-group CLIENTS
 neighbor $4 remote-as 65000
 neighbor $4 update-source 10.255.0.$2
 neighbor $4 timers connect 5
 !
 address-family ipv4 unicast
  neighbor CLIENTS activate
  neighbor CLIENTS route-reflector-client
  neighbor $4 activate
 exit-address-family
exit
!
CFG
}
rr rr1 11 10.0.0.9  10.255.0.12
rr rr2 12 10.0.0.11 10.255.0.11

echo "Phase 3a files written. Next: sudo containerlab deploy -t mini-iliad.clab.yml --reconfigure"
