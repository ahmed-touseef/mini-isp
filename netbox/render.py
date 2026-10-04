#!/usr/bin/env python3
"""Phase 6c: render FRR configs for our own routers from NetBox (source of truth).

Underlay (interfaces, IS-IS, Segment Routing, BFD) comes from NetBox data.
BGP and routing policy come from configs/policy/<device>.conf.
Output: generated/<device>.conf. Other companies' routers are not generated.
Usage: render.py [device ...]   (no arguments renders all of ours)
"""
import json, re, sys
from pathlib import Path
from urllib.request import Request, urlopen
import yaml
from jinja2 import Environment, FileSystemLoader, StrictUndefined

ROOT = Path(__file__).resolve().parent.parent
URL = "http://127.0.0.1:8800"
AUTH = (ROOT / "secrets" / "netbox-token.txt").read_text().strip()
OUR_ROLES = {"core-router", "route-reflector", "border-router", "bng", "dns-resolver"}
NO_SR = {"dns-resolver"}
OVERLOAD = {"route-reflector", "dns-resolver"}

def get(path):
    req = Request(URL + path, headers={"Accept": "application/json", "Authorization": AUTH})
    with urlopen(req) as r:
        return json.load(r)

def natural(name):
    return [int(t) if t.isdigit() else t for t in re.split(r"(\d+)", name)]

def exec_managed():
    """Addresses set by containerlab exec lines (dummy LANs, anycast, wg0) are not FRR's job."""
    topo = yaml.safe_load((ROOT / "mini-iliad.clab.yml").read_text())
    out = set()
    for n, spec in topo["topology"]["nodes"].items():
        for cmd in (spec or {}).get("exec", []):
            m = re.search(r"ip addr add (\S+) dev (\S+)", cmd)
            if m:
                out.add((n, m.group(2)))
    return out

def main():
    only = set(sys.argv[1:])
    managed = exec_managed()
    devices = get("/api/dcim/devices/?limit=1000")["results"]
    role = {d["name"]: d["role"]["slug"] for d in devices}
    env = Environment(loader=FileSystemLoader(ROOT / "netbox" / "templates"), trim_blocks=True,
                      lstrip_blocks=True, undefined=StrictUndefined, keep_trailing_newline=True)
    tpl = env.get_template("frr.j2")
    outdir = ROOT / "generated"
    outdir.mkdir(exist_ok=True)
    for d in sorted(devices, key=lambda d: d["name"]):
        name = d["name"]
        if role[name] not in OUR_ROLES or (only and name not in only):
            continue
        ifaces = get(f"/api/dcim/interfaces/?device_id={d['id']}&limit=1000")["results"]
        ips = get(f"/api/ipam/ip-addresses/?device_id={d['id']}&limit=1000")["results"]
        by_if = {}
        for ip in ips:
            ifn = ip["assigned_object"]["name"]
            if (name, ifn) not in managed:
                by_if.setdefault(ifn, []).append(ip["address"])
        loop = [a for a in by_if.get("lo", []) if a.startswith("10.255.0.")]
        if not loop:
            print(f"  SKIP {name}: no loopback in NetBox")
            continue
        idx = int(loop[0].split("/")[0].split(".")[-1])
        rendered = []
        for i in ifaces:
            n = i["name"]
            if n not in by_if:
                continue
            peer = (i.get("link_peers") or [None])[0]
            pdev = peer["device"]["name"] if peer else None
            rendered.append({
                "name": n,
                "desc": f"to {pdev}:{peer['name']}" if peer else "",
                "ips": sorted(by_if[n]),
                "isis": n == "lo" or role.get(pdev) in OUR_ROLES,
                "metric": (i.get("custom_fields") or {}).get("isis_metric"),
            })
        rendered.sort(key=lambda x: (x["name"] == "lo", natural(x["name"])))
        pf = ROOT / "configs" / "policy" / f"{name}.conf"
        text = tpl.render(name=name, idx=idx, sr=role[name] not in NO_SR, overload=role[name] in OVERLOAD,
                          interfaces=rendered, policy=pf.read_text() if pf.exists() else "")
        (outdir / f"{name}.conf").write_text(text)
        print(f"  rendered generated/{name}.conf  ({len(rendered)} interfaces, role {role[name]})")

if __name__ == "__main__":
    main()
