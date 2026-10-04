#!/usr/bin/env bash
# Phase 4a: Segment Routing MPLS on IS-IS. Edits files only.
set -eu
cd "$(dirname "$0")"
if grep -q "segment-routing on" configs/milan.conf; then echo "Phase 4a already applied"; exit 0; fi

# 1. Topology: a label table in every container, MPLS input on internal interfaces only
sed -i 's|^    image: quay.io/frrouting/frr:10.2.1$|&\n    sysctls:\n      net.mpls.platform_labels: "1048575"|' mini-iliad.clab.yml
mpls_if() {  # node, internal interfaces
  local n=$1; shift
  sed -i "/^    $n:\$/,/ip_forward=1/ s|^\( *\)- sysctl -w net.ipv4.ip_forward=1\$|&\n\1- sh -c 'for i in $*; do sysctl -w net.mpls.conf.\$i.input=1; done'|" mini-iliad.clab.yml
}
mpls_if milan   eth1 eth2 eth3 eth4
mpls_if rome    eth1 eth2 eth3
mpls_if naples  eth1 eth2 eth3
mpls_if bologna eth1 eth2
mpls_if rr1     eth1
mpls_if rr2     eth1
mpls_if br1     eth1
mpls_if br2     eth1

# 2. IS-IS: Segment Routing with one node SID per loopback
sr() {  # node index
  sed -i '/^end$/d' configs/$1.conf
  cat >> configs/$1.conf <<CFG
router isis CORE
 segment-routing on
 segment-routing global-block 16000 23999
 segment-routing prefix 10.255.0.$2/32 index $2
exit
!
CFG
}
sr milan 1; sr rome 2; sr naples 3; sr bologna 4
sr br1 5;   sr br2 6;  sr rr1 11;   sr rr2 12

echo "Phase 4a files written. Next: sudo containerlab deploy -t mini-iliad.clab.yml --reconfigure"
