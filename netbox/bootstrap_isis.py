#!/usr/bin/env python3
"""Phase 6c: add an 'isis_metric' custom field to interfaces and load current metrics from configs (idempotent)."""
import json
from pathlib import Path
from urllib.request import Request, urlopen
from urllib.error import HTTPError

ROOT = Path(__file__).resolve().parent.parent
URL = "http://127.0.0.1:8800"
AUTH = (ROOT / "secrets" / "netbox-token.txt").read_text().strip()

def call(method, path, data=None):
    req = Request(URL + path, data=json.dumps(data).encode() if data is not None else None, method=method,
                  headers={"Accept": "application/json", "Content-Type": "application/json", "Authorization": AUTH})
    try:
        with urlopen(req) as r:
            t = r.read()
            return r.status, (json.loads(t) if t else None)
    except HTTPError as e:
        return e.code, e.read().decode(errors="replace")

st, r = call("GET", "/api/extras/custom-fields/?name=isis_metric")
if r["count"] == 0:
    st, r = call("POST", "/api/extras/custom-fields/", {
        "name": "isis_metric", "label": "IS-IS metric", "type": "integer", "object_types": ["dcim.interface"],
        "description": "IS-IS metric of this link; empty means the default (10)", "required": False})
    print("custom field isis_metric:", "created" if st in (200, 201) else f"ERROR HTTP {st} {str(r)[:300]}")
else:
    print("custom field isis_metric: already exists")

for f in sorted((ROOT / "configs").glob("*.conf")):
    node, cur = f.stem, None
    for line in f.read_text().splitlines():
        if line.startswith("interface "):
            cur = line.split()[1]
        elif not line.startswith(" "):
            cur = None
        elif cur and line.strip().startswith("isis metric "):
            metric = int(line.split()[2])
            st, r = call("GET", f"/api/dcim/interfaces/?device={node}&name={cur}")
            if r["count"]:
                st, _ = call("PATCH", f"/api/dcim/interfaces/{r['results'][0]['id']}/", {"custom_fields": {"isis_metric": metric}})
                print(f"  {node} {cur}: isis_metric {metric} ({'set' if st == 200 else 'ERROR ' + str(st)})")
