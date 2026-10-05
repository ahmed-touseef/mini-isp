#!/usr/bin/env python3
"""Mini ISP telemetry exporter.

Every 10 s it reads the lab routers through `docker exec` (vtysh JSON, ip -s -j link,
conntrack, wg) and serves Prometheus metrics on http://127.0.0.1:9101/metrics.
Runs as root for docker access. Only listens on localhost.
"""
import json, re, subprocess, threading, time
from concurrent.futures import ThreadPoolExecutor
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

PREFIX = "clab-miniiliad-"
ROUTERS = ["milan", "rome", "naples", "bologna", "rr1", "rr2", "br1", "br2", "bng", "dns-mi", "dns-na"]
INTERVAL = 10
LISTEN = ("127.0.0.1", 9101)
SKIP_IF = ("lo", "eth0", "gre", "gretap", "erspan", "sit", "tunl", "ip6", "ip_vti", "ip6_vti", "ip6gre", "ip6tnl")

TYPES = {
    "mini_isp_up": ("gauge", "1 if the exporter could read the router"),
    "mini_isp_iface_rx_bytes_total": ("counter", "Bytes received on an interface"),
    "mini_isp_iface_tx_bytes_total": ("counter", "Bytes sent on an interface"),
    "mini_isp_iface_rx_packets_total": ("counter", "Packets received on an interface"),
    "mini_isp_iface_tx_packets_total": ("counter", "Packets sent on an interface"),
    "mini_isp_iface_up": ("gauge", "1 if the interface has carrier"),
    "mini_isp_bgp_session_up": ("gauge", "1 if the BGP session is Established"),
    "mini_isp_bgp_prefixes_received": ("gauge", "Prefixes received from the BGP peer"),
    "mini_isp_isis_adjacency_up": ("gauge", "1 if the IS-IS adjacency is Up"),
    "mini_isp_bfd_peer_up": ("gauge", "1 if the BFD session is up"),
    "mini_isp_cgnat_sessions": ("gauge", "Connection tracking entries on the BNG (CGNAT translations)"),
    "mini_isp_dhcp_leases": ("gauge", "Active DHCP leases on the BNG"),
    "mini_isp_wg_last_handshake_timestamp": ("gauge", "Unix time of the latest WireGuard handshake per peer"),
    "mini_isp_collect_seconds": ("gauge", "Time taken by the last collection cycle"),
}

metrics_text = "# no data collected yet\n"
lock = threading.Lock()

def dx(node, *cmd, timeout=8):
    r = subprocess.run(["docker", "exec", PREFIX + node, *cmd], capture_output=True, text=True, timeout=timeout)
    if r.returncode != 0:
        raise RuntimeError(r.stderr.strip()[:200])
    return r.stdout

def vtysh_json(node, cmd):
    out = dx(node, "vtysh", "-c", cmd).strip()
    return json.loads(out) if out else {}

def sample(name, labels, value):
    lab = ",".join('%s="%s"' % (k, str(v).replace("\\", "\\\\").replace('"', '\\"')) for k, v in labels.items())
    return (name, "%s{%s} %s" % (name, lab, value))

def collect_node(node):
    out = []
    try:
        for i in json.loads(dx(node, "ip", "-s", "-j", "link", "show")):
            name = i.get("ifname", "")
            if name.startswith(SKIP_IF):
                continue
            st, lab = i.get("stats64", {}), {"router": node, "iface": name}
            out.append(sample("mini_isp_iface_rx_bytes_total", lab, st.get("rx", {}).get("bytes", 0)))
            out.append(sample("mini_isp_iface_tx_bytes_total", lab, st.get("tx", {}).get("bytes", 0)))
            out.append(sample("mini_isp_iface_rx_packets_total", lab, st.get("rx", {}).get("packets", 0)))
            out.append(sample("mini_isp_iface_tx_packets_total", lab, st.get("tx", {}).get("packets", 0)))
            out.append(sample("mini_isp_iface_up", lab, 1 if "LOWER_UP" in i.get("flags", []) else 0))

        s = vtysh_json(node, "show bgp ipv4 unicast summary json")
        s = s.get("ipv4Unicast", s) if isinstance(s, dict) else {}
        for ip, p in (s.get("peers") or {}).items():
            lab = {"router": node, "peer": ip, "peer_name": p.get("desc") or p.get("hostname") or ip}
            out.append(sample("mini_isp_bgp_session_up", lab, 1 if p.get("state") == "Established" else 0))
            out.append(sample("mini_isp_bgp_prefixes_received", lab, p.get("pfxRcd", p.get("prefixReceivedCount", 0)) or 0))

        txt = dx(node, "vtysh", "-c", "show isis neighbor")
        for m in re.finditer(r"^\s*(\S+)\s+(eth\d+)\s+\d\s+(\S+)", txt, re.M):
            out.append(sample("mini_isp_isis_adjacency_up", {"router": node, "neighbor": m[1], "iface": m[2]}, 1 if m[3] == "Up" else 0))

        peers = vtysh_json(node, "show bfd peers json")
        for p in peers if isinstance(peers, list) else []:
            out.append(sample("mini_isp_bfd_peer_up", {"router": node, "peer": p.get("peer", ""), "iface": p.get("interface", "")},
                              1 if p.get("status") == "up" else 0))

        if node == "bng":
            n = dx(node, "sh", "-c", "conntrack -C 2>/dev/null || echo 0").strip() or "0"
            out.append(sample("mini_isp_cgnat_sessions", {"router": node}, int(n)))
            n = dx(node, "sh", "-c", "wc -l < /tmp/dnsmasq.leases 2>/dev/null || echo 0").strip() or "0"
            out.append(sample("mini_isp_dhcp_leases", {"router": node}, int(n)))
            for ln in dx(node, "sh", "-c", "wg show wg0 latest-handshakes 2>/dev/null || true").splitlines():
                parts = ln.split()
                if len(parts) == 2:
                    out.append(sample("mini_isp_wg_last_handshake_timestamp", {"router": node, "peer": parts[0][:8]}, int(parts[1])))
        out.append(sample("mini_isp_up", {"router": node}, 1))
    except Exception:
        out.append(sample("mini_isp_up", {"router": node}, 0))
    return out

def collector():
    global metrics_text
    with ThreadPoolExecutor(max_workers=6) as pool:
        while True:
            t0 = time.time()
            samples = [s for res in pool.map(collect_node, ROUTERS) for s in res]
            samples.append(("mini_isp_collect_seconds", "mini_isp_collect_seconds %.3f" % (time.time() - t0)))
            body, by_name = [], {}
            for name, text in samples:
                by_name.setdefault(name, []).append(text)
            for name in sorted(by_name):
                kind, helptext = TYPES.get(name, ("gauge", name))
                body += ["# HELP %s %s" % (name, helptext), "# TYPE %s %s" % (name, kind)] + by_name[name]
            with lock:
                metrics_text = "\n".join(body) + "\n"
            time.sleep(max(1, INTERVAL - (time.time() - t0)))

class Handler(BaseHTTPRequestHandler):
    def do_GET(self):
        if self.path.split("?")[0] != "/metrics":
            self.send_response(404); self.end_headers(); return
        with lock:
            data = metrics_text.encode()
        self.send_response(200)
        self.send_header("Content-Type", "text/plain; version=0.0.4")
        self.end_headers()
        self.wfile.write(data)
    def log_message(self, *a):
        pass

if __name__ == "__main__":
    threading.Thread(target=collector, daemon=True).start()
    ThreadingHTTPServer(LISTEN, Handler).serve_forever()
