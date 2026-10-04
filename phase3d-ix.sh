#!/usr/bin/env bash
# Phase 3d: MIX internet exchange with a route server and two peers. Edits files only.
set -eu
cd "$(dirname "$0")"
if [ -f configs/rs.conf ]; then echo "Phase 3d already applied"; exit 0; fi
B="configs/daemons:/etc/frr/daemons, configs/vtysh.conf:/etc/frr/vtysh.conf"

# 1. Topology: new nodes go before "links:", new links go at the end
cat > /tmp/ix-nodes.yml <<YML
    mix:
      exec:
        - ip link add br0 type bridge
        - ip link set br0 up
        - ip link set eth1 master br0
        - ip link set eth2 master br0
        - ip link set eth3 master br0
        - ip link set eth4 master br0
    rs:
      binds: [configs/rs.conf:/etc/frr/frr.conf, $B]
      exec:
        - sysctl -w net.ipv4.ip_forward=1
    fastweb:
      binds: [configs/fastweb.conf:/etc/frr/frr.conf, $B]
      exec:
        - sysctl -w net.ipv4.ip_forward=1
        - ip link add svc0 type dummy
        - ip link set svc0 up
        - ip addr add 198.18.1.1/24 dev svc0
    netflix:
      binds: [configs/netflix.conf:/etc/frr/frr.conf, $B]
      exec:
        - sysctl -w net.ipv4.ip_forward=1
        - ip link add svc0 type dummy
        - ip link set svc0 up
        - ip addr add 198.18.2.1/24 dev svc0

YML
awk '/^  links:/{while((getline l < "/tmp/ix-nodes.yml")>0) print l} {print}' mini-iliad.clab.yml > /tmp/clab.yml
mv /tmp/clab.yml mini-iliad.clab.yml
cat >> mini-iliad.clab.yml <<'YML'
    - endpoints: ["br1:eth3", "mix:eth1"]              # MIX peering LAN 10.200.0.0/24
    - endpoints: ["rs:eth1", "mix:eth2"]
    - endpoints: ["fastweb:eth1", "mix:eth3"]
    - endpoints: ["netflix:eth1", "mix:eth4"]
    - endpoints: ["fastweb:eth2", "internet:eth3"]     # 10.100.5.0/31
    - endpoints: ["netflix:eth2", "internet:eth4"]     # 10.100.6.0/31
YML

# 2. br1: join the exchange with a peering policy
sed -i '/^end$/d' configs/br1.conf
cat >> configs/br1.conf <<'CFG'
interface eth3
 description MIX-PEERING-LAN
 ip address 10.200.0.2/24
exit
!
bgp as-path access-list PEER-ONLY permit ^[0-9]+$
!
route-map IX-IN deny 5
 match ip address prefix-list BOGONS
exit
route-map IX-IN deny 6
 match ip address prefix-list OUR-SPACE
exit
route-map IX-IN permit 10
 match as-path PEER-ONLY
 set local-preference 300
exit
!
route-map IX-OUT permit 10
 match ip address prefix-list OUR-PREFIXES
exit
!
router bgp 65000
 neighbor 10.200.0.1 remote-as 65300
 neighbor 10.200.0.1 description MIX-ROUTE-SERVER
 neighbor 10.200.0.1 timers connect 5
 no neighbor 10.200.0.1 enforce-first-as
 !
 address-family ipv4 unicast
  neighbor 10.200.0.1 activate
  neighbor 10.200.0.1 soft-reconfiguration inbound
  neighbor 10.200.0.1 maximum-prefix 100 80 restart 5
  neighbor 10.200.0.1 route-map IX-IN in
  neighbor 10.200.0.1 route-map IX-OUT out
 exit-address-family
exit
!
CFG

# 3. Route server
cat > configs/rs.conf <<'CFG'
frr defaults traditional
hostname rs
service integrated-vtysh-config
!
interface eth1
 ip address 10.200.0.1/24
exit
!
router bgp 65300
 bgp router-id 10.200.0.1
 no bgp ebgp-requires-policy
 neighbor MEMBERS peer-group
 neighbor MEMBERS timers connect 5
 neighbor 10.200.0.2 remote-as 65000
 neighbor 10.200.0.2 peer-group MEMBERS
 neighbor 10.200.0.11 remote-as 65401
 neighbor 10.200.0.11 peer-group MEMBERS
 neighbor 10.200.0.12 remote-as 65402
 neighbor 10.200.0.12 peer-group MEMBERS
 !
 address-family ipv4 unicast
  neighbor MEMBERS activate
  neighbor MEMBERS route-server-client
 exit-address-family
exit
!
CFG

# 4. Peers: announce only their own prefix, to the exchange and to transit
peer() {  # name as ix_ip transit_ip transit_peer prefix
  cat > configs/$1.conf <<CFG
frr defaults traditional
hostname $1
service integrated-vtysh-config
!
interface eth1
 ip address $3/24
exit
!
interface eth2
 ip address $4/31
exit
!
ip prefix-list OWN seq 5 permit $6
!
route-map OWN-ONLY permit 10
 match ip address prefix-list OWN
exit
!
router bgp $2
 bgp router-id $3
 no bgp ebgp-requires-policy
 neighbor 10.200.0.1 remote-as 65300
 neighbor 10.200.0.1 timers connect 5
 no neighbor 10.200.0.1 enforce-first-as
 neighbor $5 remote-as 65200
 neighbor $5 timers connect 5
 !
 address-family ipv4 unicast
  network $6
  neighbor 10.200.0.1 route-map OWN-ONLY out
  neighbor $5 route-map OWN-ONLY out
 exit-address-family
exit
!
CFG
}
peer fastweb 65401 10.200.0.11 10.100.5.0 10.100.5.1 198.18.1.0/24
peer netflix 65402 10.200.0.12 10.100.6.0 10.100.6.1 198.18.2.0/24

# 5. The internet now also serves both peers as their transit provider
cat >> configs/internet.conf <<'CFG'
interface eth3
 ip address 10.100.5.1/31
exit
!
interface eth4
 ip address 10.100.6.1/31
exit
!
router bgp 65200
 neighbor 10.100.5.0 remote-as 65401
 neighbor 10.100.5.0 timers connect 5
 neighbor 10.100.6.0 remote-as 65402
 neighbor 10.100.6.0 timers connect 5
exit
!
CFG

echo "Phase 3d files written. Next: sudo containerlab deploy -t mini-iliad.clab.yml --reconfigure"
