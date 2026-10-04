#!/usr/bin/env bash
# Phase 5c: anycast DNS. Two Unbound resolvers share 192.0.2.53, announced in BGP. Edits files only.
set -eu
cd "$(dirname "$0")"
if [ -f configs/dns-mi.conf ]; then echo "Phase 5c already applied"; exit 0; fi
B="configs/daemons:/etc/frr/daemons, configs/vtysh.conf:/etc/frr/vtysh.conf"

# 1. Topology
node() {  # name unbound_conf
cat <<YML
    $1:
      binds: [configs/$1.conf:/etc/frr/frr.conf, configs/$2:/etc/unbound/unbound.conf, $B]
      exec:
        - apk add --no-cache -q unbound
        - ip link add any0 type dummy
        - ip link set any0 up
        - ip addr add 192.0.2.53/32 dev any0
        - unbound -c /etc/unbound/unbound.conf
YML
}
{ node dns-mi unbound-mi.conf; node dns-na unbound-na.conf; echo; } > /tmp/dns-nodes.yml
awk '/^  links:/{while((getline l < "/tmp/dns-nodes.yml")>0) print l} {print}' mini-iliad.clab.yml > /tmp/clab.yml
mv /tmp/clab.yml mini-iliad.clab.yml
cat >> mini-iliad.clab.yml <<'YML'
    - endpoints: ["milan:eth6", "dns-mi:eth1"]         # 10.0.0.18/31
    - endpoints: ["naples:eth4", "dns-na:eth1"]        # 10.0.0.20/31
YML
# DHCP now hands out the anycast resolver
sed -i 's|--dhcp-option=option:router,100.64.0.1|& --dhcp-option=option:dns-server,192.0.2.53|' mini-iliad.clab.yml

# 2. Core links towards the resolvers
corelink() {  # node iface ip
  sed -i '/^end$/d' configs/$1.conf
  cat >> configs/$1.conf <<CFG
interface $2
 description DNS-RESOLVER
 ip address $3/31
 ip router isis CORE
 isis network point-to-point
 isis bfd
 isis bfd profile FAST
exit
!
CFG
}
corelink milan  eth6 10.0.0.18
corelink naples eth4 10.0.0.20

# 3. Route reflectors gain two clients
sed -i '/neighbor 10.255.0.7 peer-group CLIENTS/a\ neighbor 10.255.0.8 peer-group CLIENTS\n neighbor 10.255.0.9 peer-group CLIENTS' configs/rr1.conf configs/rr2.conf

# 4. Resolver routers: IS-IS (overload, never transit), BFD, iBGP announcing the anycast /32
resolver() {  # name id link_ip
  cat > configs/$1.conf <<CFG
frr defaults traditional
hostname $1
service integrated-vtysh-config
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
 ip address $3/31
 ip router isis CORE
 isis network point-to-point
 isis bfd
 isis bfd profile FAST
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
 net 49.0001.0102.5500.000$2.00
 lsp-gen-interval 1
 spf-interval 1
 set-overload-bit
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
 !
 address-family ipv4 unicast
  network 192.0.2.53/32
  neighbor RR activate
 exit-address-family
exit
!
CFG
}
resolver dns-mi 8 10.0.0.19
resolver dns-na 9 10.0.0.21

# 5. Unbound: only lab names exist; whoami.lab reveals which server answered
unbound() {  # file own_loopback
  cat > configs/$1 <<CFG
server:
  interface: 192.0.2.53
  access-control: 0.0.0.0/0 refuse
  access-control: 192.0.2.0/24 allow
  access-control: 100.64.0.0/10 allow
  access-control: 10.0.0.0/8 allow
  do-ip6: no
  username: ""
  chroot: ""
  use-syslog: no
  local-zone: "." static
  local-zone: "lab." static
  local-data: "web.internet.lab. A 198.51.100.1"
  local-data: "fastweb.lab. A 198.18.1.1"
  local-data: "netflix.lab. A 198.18.2.1"
  local-data: "whoami.lab. A $2"
CFG
}
unbound unbound-mi.conf 10.255.0.8
unbound unbound-na.conf 10.255.0.9

echo "Phase 5c files written. Next: sudo containerlab deploy -t mini-iliad.clab.yml --reconfigure"
