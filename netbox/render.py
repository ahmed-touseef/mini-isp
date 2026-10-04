#!/usr/bin/env python3
"""Render FRR configs for our own routers from NetBox (source of truth).

Online (default): reads the NetBox API and saves the data it used to netbox/snapshot.json.
Offline: --snapshot netbox/snapshot.json renders from that file (used by CI, no NetBox needed).
Underlay (interfaces, IS-IS, Segment Routing, BFD) comes from NetBox data;
BGP and routing policy come from configs/policy/<device>.conf.
Output: generated/<device>.conf for every router in AS 65000.
"""
import argparse, json, re
from pathlib import Path
from urllib.request import Request, urlopen
import yaml
from jinja2 import Environment, FileSystemLoader, StrictUndefined

ROOT = Path(__file__).resolve().parent.parent
URL = "http://127.0.0.1:8800"
SNAPSHOT = ROOT / "netbox" / "snapshot.json"
OUR_ROLES = {"core-router", "route-reflector", "border-router", "bng", "dns-resolver"}
NO_SR = {"dns-resolver"}
OVERLOAD = {"route-reflector", "dns-resolver"}

def natural(name):
    return [int(t) if t.isdigit() else t for t in re.split(r"(\d+)", name)]

def load_online():
    auth = (ROOT / "secrets" / "netbox-token.txt").read_text().strip()
    def get(path):
        with urlopen(Request(URL + path, headers={"Accept": "application/json", "Authorization": auth})) as r:
            return json.load(r)
    devs = get("/api/dcim/devices/?limit=1000")["results"]
    inv = {"devices": sorted([{"name": d["name"], "role": d["role"]["slug"]} for d in devs], key=lambda x: x["name"]),
           "interfaces": {}, "ips": {}}
    for d in devs:
        if d["role"]["slug"] not in OUR_ROLES:
            continue
        ifs = []
        for i in get(f"/api/dcim/interfaces/?device_id={d['id']}&limit=1000")["results"]:
            p = (i.get("link_peers") or [None])[0]
            ifs.append({"name": i["name"], "peer": f"{p['device']['name']}:{p['name']}" if p else None,
                        "isis_metric": (i.get("custom_fields") or {}).get("isis_metric")})
        inv["interfaces"][d["name"]] = sorted(ifs, key=lambda x: natural(x["name"]))
        ips = [{"address": ip["address"], "interface": ip["assigned_object"]["name"]}
               for ip in get(f"/api/ipam/ip-addresses/?device_id={d['id']}&limit=1000")["results"]]
        inv["ips"][d["name"]] = sorted(ips, key=lambda x: (natural(x["interface"]), x["address"]))
    return inv

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

def render(inv):
    managed = exec_managed()
    role = {d["name"]: d["role"] for d in inv["devices"]}
    env = Environment(loader=FileSystemLoader(ROOT / "netbox" / "templates"), trim_blocks=True,
                      lstrip_blocks=True, undefined=StrictUndefined, keep_trailing_newline=True)
    tpl = env.get_template("frr.j2")
    outdir = ROOT / "generated"
    outdir.mkdir(exist_ok=True)
    for name in sorted(inv["interfaces"]):
        by_if = {}
        for ip in inv["ips"][name]:
            if (name, ip["interface"]) not in managed:
                by_if.setdefault(ip["interface"], []).append(ip["address"])
        loop = [a for a in by_if.get("lo", []) if a.startswith("10.255.0.")]
        if not loop:
            print(f"  SKIP {name}: no loopback")
            continue
        idx = int(loop[0].split("/")[0].split(".")[-1])
        rendered = []
        for i in inv["interfaces"][name]:
            n = i["name"]
            if n not in by_if:
                continue
            pdev = i["peer"].split(":")[0] if i["peer"] else None
            rendered.append({"name": n, "desc": f"to {i['peer']}" if i["peer"] else "", "ips": sorted(by_if[n]),
                             "isis": n == "lo" or role.get(pdev) in OUR_ROLES, "metric": i["isis_metric"]})
        rendered.sort(key=lambda x: (x["name"] == "lo", natural(x["name"])))
        pf = ROOT / "configs" / "policy" / f"{name}.conf"
        text = tpl.render(name=name, idx=idx, sr=role[name] not in NO_SR, overload=role[name] in OVERLOAD,
                          interfaces=rendered, policy=pf.read_text() if pf.exists() else "")
        (outdir / f"{name}.conf").write_text(text)
        print(f"  rendered generated/{name}.conf  ({len(rendered)} interfaces, role {role[name]})")

def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--snapshot", help="render offline from this snapshot file instead of the NetBox API")
    args = ap.parse_args()
    if args.snapshot:
        inv = json.loads(Path(args.snapshot).read_text())
    else:
        inv = load_online()
        SNAPSHOT.write_text(json.dumps(inv, indent=1, sort_keys=True) + "\n")
        print(f"  saved {SNAPSHOT.relative_to(ROOT)}")
    render(inv)

if __name__ == "__main__":
    main()
