#!/usr/bin/env python3
"""Phase 6b: import the lab into NetBox (idempotent).

Reads mini-iliad.clab.yml and configs/*.conf, then creates sites, roles,
device types, devices, interfaces, cables, IP addresses, ASNs and prefixes
through the NetBox REST API. Existing objects are reused, so it is safe to rerun.
The API token is kept in secrets/netbox-token.txt and never printed.
"""
import json, os, re, sys
from pathlib import Path
from urllib.request import Request, urlopen
from urllib.error import HTTPError
from urllib.parse import urlencode
import yaml

ROOT = Path(__file__).resolve().parent.parent
SECRETS = ROOT / "secrets"
URL = "http://127.0.0.1:8800"
AUTH = None
created = {}

# ---------- API helpers ----------
def call(method, path, data=None, auth=True):
    headers = {"Accept": "application/json", "Content-Type": "application/json"}
    if auth and AUTH:
        headers["Authorization"] = AUTH
    body = json.dumps(data).encode() if data is not None else None
    req = Request(URL + path, data=body, headers=headers, method=method)
    try:
        with urlopen(req) as r:
            txt = r.read()
            return r.status, (json.loads(txt) if txt else None)
    except HTTPError as e:
        return e.code, e.read().decode(errors="replace")

def save_secret(name, value):
    fd = os.open(SECRETS / name, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
    with os.fdopen(fd, "w") as f:
        f.write(value)

def authenticate():
    global AUTH
    tf = SECRETS / "netbox-token.txt"
    if tf.exists():
        AUTH = tf.read_text().strip()
        if call("GET", "/api/dcim/sites/?limit=1")[0] == 200:
            print("Using saved API token")
            return
    pw = (SECRETS / "netbox-admin.txt").read_text().strip()
    st, r = call("POST", "/api/users/tokens/provision/", {"username": "admin", "password": pw}, auth=False)
    if st not in (200, 201) or not isinstance(r, dict):
        sys.exit(f"Token provisioning failed with HTTP {st}")
    tok, key = r.get("token"), r.get("key")
    cands = []
    if tok and str(tok).startswith("nbt_"):
        cands.append(f"Bearer {tok}")
    if tok and key:
        cands += [f"Bearer nbt_{key}.{tok}", f"Bearer {tok}", f"Token {tok}"]
    if key:
        cands.append(f"Token {key}")
    if tok:
        cands.append(f"Token {tok}")
    for h in cands:
        AUTH = h
        if call("GET", "/api/dcim/sites/?limit=1")[0] == 200:
            save_secret("netbox-token.txt", h)
            print("API token created and saved to secrets/netbox-token.txt")
            return
    sys.exit("Could not authenticate with the provisioned token")

def slug(s):
    return re.sub(r"[^a-z0-9]+", "-", s.lower()).strip("-")

def goc(endpoint, lookup, data, label):
    """Get or create one object."""
    st, r = call("GET", f"/api/{endpoint}/?{urlencode(lookup)}")
    if st == 200 and r["count"] > 0:
        return r["results"][0]
    st, r = call("POST", f"/api/{endpoint}/", data)
    if st in (200, 201):
        created[label] = created.get(label, 0) + 1
        return r
    print(f"  ERROR creating {label} {lookup}: HTTP {st} {str(r)[:300]}")
    return None

# ---------- Intent: what the lab is ----------
SITES = {
    "Milan": ["milan", "rr1", "br1", "bng", "dns-mi", "olt", "home1", "home2", "mix", "rs", "fastweb", "netflix"],
    "Rome": ["rome", "br2"],
    "Naples": ["naples", "rr2", "dns-na"],
    "Bologna": ["bologna"],
    "Internet (simulated)": ["arelion", "cogent", "internet"],
}
ROLES = {
    "Core router": ("2196f3", ["milan", "rome", "naples", "bologna"]),
    "Route reflector": ("9c27b0", ["rr1", "rr2"]),
    "Border router": ("ff5722", ["br1", "br2"]),
    "BNG": ("4caf50", ["bng"]),
    "DNS resolver": ("009688", ["dns-mi", "dns-na"]),
    "Access switch (OLT)": ("8bc34a", ["olt"]),
    "Exchange switch": ("607d8b", ["mix"]),
    "Route server": ("795548", ["rs"]),
    "Peer": ("ffc107", ["fastweb", "netflix"]),
    "Transit provider": ("f44336", ["arelion", "cogent"]),
    "Internet": ("9e9e9e", ["internet"]),
    "Customer": ("00bcd4", ["home1", "home2"]),
}
ASNS = {
    65000: "Mini ISP (us)", 65101: "Arelion (transit, simulated)", 65102: "Cogent (transit, simulated)",
    65200: "Internet (simulated)", 65300: "MIX route server", 65401: "Fastweb (peer, simulated)",
    65402: "Netflix (peer, simulated)",
}
PREFIXES = [
    ("192.0.2.0/24", "container", "Mini ISP public space, announced as one aggregate"),
    ("192.0.2.0/26", "active", "Milan customer pool"),
    ("192.0.2.64/26", "active", "Rome customer pool"),
    ("192.0.2.128/26", "active", "Naples customer pool"),
    ("192.0.2.192/26", "active", "Bologna customer pool"),
    ("192.0.2.32/28", "active", "CGNAT public pool on the BNG"),
    ("100.64.0.0/16", "container", "CGNAT subscriber space (RFC 6598)"),
    ("100.64.0.0/24", "active", "Fibre homes, DHCP"),
    ("100.64.1.0/24", "active", "WireGuard subscribers"),
    ("10.255.0.0/24", "active", "Loopbacks"),
    ("10.0.0.0/24", "active", "Core point to point links (/31)"),
    ("10.100.0.0/16", "active", "Transit and peer links"),
    ("10.200.0.0/24", "active", "MIX peering LAN"),
]
VIRTUAL = ("lo", "cust", "svc", "web", "any", "wg", "br")

def kind_of(node):
    if node in ("olt", "mix"):
        return "Linux bridge", "Linux"
    if node.startswith("home"):
        return "Linux host", "Linux"
    return "FRR router", "FRRouting"

def frr_addresses(node):
    f = ROOT / "configs" / f"{node}.conf"
    out, cur = [], None
    if not f.exists():
        return out
    for line in f.read_text().splitlines():
        if line.startswith("interface "):
            cur = line.split()[1]
        elif not line.startswith(" "):
            cur = None
        elif cur and line.strip().startswith("ip address "):
            out.append((cur, line.split()[2]))
    return out

# ---------- Import ----------
def main():
    authenticate()
    topo = yaml.safe_load((ROOT / "mini-iliad.clab.yml").read_text())
    nodes = topo["topology"]["nodes"]
    links = [l["endpoints"] for l in topo["topology"]["links"]]

    addrs = {}  # node -> set of (iface, cidr)
    for n, spec in nodes.items():
        s = set(frr_addresses(n))
        for cmd in (spec or {}).get("exec", []):
            m = re.search(r"ip addr add (\S+) dev (\S+)", cmd)
            if m:
                s.add((m.group(2), m.group(1)))
        addrs[n] = s

    site_of = {d: s for s, ds in SITES.items() for d in ds}
    role_of = {d: r for r, (_, ds) in ROLES.items() for d in ds}

    site_id = {s: goc("dcim/sites", {"slug": slug(s)}, {"name": s, "slug": slug(s), "status": "active"}, "sites")["id"] for s in SITES}
    role_id = {r: goc("dcim/device-roles", {"slug": slug(r)}, {"name": r, "slug": slug(r), "color": c}, "roles")["id"] for r, (c, _) in ROLES.items()}
    mfr = {m: goc("dcim/manufacturers", {"slug": slug(m)}, {"name": m, "slug": slug(m)}, "manufacturers")["id"] for m in ("FRRouting", "Linux")}
    plat = {m: goc("dcim/platforms", {"slug": slug(m)}, {"name": m, "slug": slug(m)}, "platforms")["id"] for m in ("FRRouting", "Linux")}
    dtype = {}
    for model, m in (("FRR router", "FRRouting"), ("Linux bridge", "Linux"), ("Linux host", "Linux")):
        dtype[model] = goc("dcim/device-types", {"slug": slug(model)},
                           {"manufacturer": mfr[m], "model": model, "slug": slug(model)}, "device types")["id"]

    dev = {}
    for n in nodes:
        model, platform = kind_of(n)
        dev[n] = goc("dcim/devices", {"name": n},
                     {"name": n, "device_type": dtype[model], "role": role_id[role_of[n]],
                      "site": site_id[site_of[n]], "platform": plat[platform], "status": "active"}, "devices")["id"]

    iface = {}
    def get_iface(n, name):
        if (n, name) not in iface:
            t = "virtual" if name.startswith(VIRTUAL) else "1000base-t"
            iface[(n, name)] = goc("dcim/interfaces", {"device_id": dev[n], "name": name},
                                   {"device": dev[n], "name": name, "type": t}, "interfaces")["id"]
        return iface[(n, name)]

    for a, b in links:
        an, ai = a.split(":"); bn, bi = b.split(":")
        ia, ib = get_iface(an, ai), get_iface(bn, bi)
        st, cur = call("GET", f"/api/dcim/interfaces/{ia}/")
        if st == 200 and cur.get("cable"):
            continue
        st, r = call("POST", "/api/dcim/cables/", {
            "a_terminations": [{"object_type": "dcim.interface", "object_id": ia}],
            "b_terminations": [{"object_type": "dcim.interface", "object_id": ib}],
            "status": "connected", "label": f"{an}:{ai} to {bn}:{bi}"})
        if st in (200, 201):
            created["cables"] = created.get("cables", 0) + 1
        else:
            print(f"  ERROR cable {a} to {b}: HTTP {st} {str(r)[:300]}")

    for n, s in addrs.items():
        for name, cidr in sorted(s):
            iid = get_iface(n, name)
            role = "anycast" if cidr == "192.0.2.53/32" else ("loopback" if name == "lo" else "")
            data = {"address": cidr, "status": "active", "assigned_object_type": "dcim.interface",
                    "assigned_object_id": iid, "description": f"{n} {name}"}
            if role:
                data["role"] = role
            ip = goc("ipam/ip-addresses", {"address": cidr, "interface_id": iid}, data, "IP addresses")
            if ip and name == "lo" and cidr.startswith("10.255.0."):
                call("PATCH", f"/api/dcim/devices/{dev[n]}/", {"primary_ip4": ip["id"]})

    rir = goc("ipam/rirs", {"slug": "private-asn"}, {"name": "Private ASN (RFC 6996)", "slug": "private-asn", "is_private": True}, "RIRs")["id"]
    for asn, desc in ASNS.items():
        goc("ipam/asns", {"asn": asn}, {"asn": asn, "rir": rir, "description": desc}, "ASNs")
    for p, status, desc in PREFIXES:
        goc("ipam/prefixes", {"prefix": p}, {"prefix": p, "status": status, "description": desc}, "prefixes")

    print("== Created this run ==")
    for k, v in created.items():
        print(f"  {k}: {v}")
    if not created:
        print("  nothing new, NetBox already matches the lab")
    print("== Totals in NetBox ==")
    for label, ep in (("sites", "dcim/sites"), ("devices", "dcim/devices"), ("interfaces", "dcim/interfaces"),
                      ("cables", "dcim/cables"), ("IP addresses", "ipam/ip-addresses"),
                      ("prefixes", "ipam/prefixes"), ("ASNs", "ipam/asns")):
        print(f"  {label}: {call('GET', f'/api/{ep}/?limit=1')[1]['count']}")

if __name__ == "__main__":
    main()
