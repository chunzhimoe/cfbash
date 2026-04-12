#!/usr/bin/env python3
"""metrics_server.py — Lightweight HTTP metrics server.
Serves JSON at http://127.0.0.1:{port}/metrics.json
Requires: Python 3 (stdlib only), optional: nvidia-smi
"""

import json, os, time, subprocess, socket, sys
from http.server import HTTPServer, BaseHTTPRequestHandler


def read_file(path):
    try:
        with open(path) as f:
            return f.read()
    except Exception:
        return ""


def cpu_percent():
    def read_stat():
        line = read_file("/proc/stat").split("\n")[0]
        fields = list(map(int, line.split()[1:]))
        idle = fields[3] + (fields[4] if len(fields) > 4 else 0)
        total = sum(fields)
        return idle, total
    i1, t1 = read_stat()
    time.sleep(0.2)
    i2, t2 = read_stat()
    dt = t2 - t1
    if dt == 0:
        return 0.0
    return round((1 - (i2 - i1) / dt) * 100, 1)


def memory():
    raw = {}
    for line in read_file("/proc/meminfo").splitlines():
        if ":" in line:
            k, v = line.split(":", 1)
            raw[k.strip()] = int(v.strip().split()[0])
    total = raw.get("MemTotal", 0)
    avail = raw.get("MemAvailable", raw.get("MemFree", 0))
    used = total - avail
    pct = round(used / total * 100, 1) if total else 0
    return {"used": used, "total": total, "percent": pct}


def disk():
    try:
        st = os.statvfs("/")
        total = st.f_blocks * st.f_frsize // 1024
        avail = st.f_bavail * st.f_frsize // 1024
        used = total - avail
        pct = round(used / total * 100, 1) if total else 0
        return {"used": used, "total": total, "percent": pct}
    except Exception:
        return {"used": 0, "total": 0, "percent": 0}


_prev_net = {}


def network():
    global _prev_net
    iface_stats = {}
    for line in read_file("/proc/net/dev").splitlines()[2:]:
        parts = line.split()
        if len(parts) < 10:
            continue
        iface = parts[0].rstrip(":")
        if iface == "lo":
            continue
        iface_stats[iface] = {"rx": int(parts[1]), "tx": int(parts[9])}
    now = time.time()
    result = {"rxBytesPerSec": 0, "txBytesPerSec": 0}
    if _prev_net:
        dt = now - _prev_net["ts"]
        if dt > 0:
            for iface, vals in iface_stats.items():
                prev = _prev_net.get(iface, {})
                if prev:
                    result["rxBytesPerSec"] += max(
                        0, int((vals["rx"] - prev["rx"]) / dt)
                    )
                    result["txBytesPerSec"] += max(
                        0, int((vals["tx"] - prev["tx"]) / dt)
                    )
    _prev_net = {"ts": now, **{k: v for k, v in iface_stats.items()}}
    return result


def load_avg():
    try:
        parts = read_file("/proc/loadavg").split()
        return [float(parts[0]), float(parts[1]), float(parts[2])]
    except Exception:
        return [0.0, 0.0, 0.0]


def uptime():
    try:
        return float(read_file("/proc/uptime").split()[0])
    except Exception:
        return 0.0


def gpu_info():
    try:
        out = subprocess.check_output(
            [
                "nvidia-smi",
                "--query-gpu=name,temperature.gpu,utilization.gpu,memory.used,memory.total",
                "--format=csv,noheader,nounits",
            ],
            timeout=3,
            stderr=subprocess.DEVNULL,
        ).decode()
        gpus = []
        for line in out.strip().splitlines():
            parts = [p.strip() for p in line.split(",")]
            if len(parts) >= 5:
                gpus.append(
                    {
                        "name": parts[0],
                        "tempC": int(parts[1]),
                        "utilPercent": int(parts[2]),
                        "memUsedMiB": int(parts[3]),
                        "memTotalMiB": int(parts[4]),
                    }
                )
        return gpus
    except Exception:
        return None


def collect():
    data = {
        "hostname": socket.gethostname(),
        "timestamp": int(time.time() * 1000),
        "cpu": cpu_percent(),
        "memory": memory(),
        "disk": disk(),
        "network": network(),
        "load": load_avg(),
        "uptime": uptime(),
    }
    gpu = gpu_info()
    if gpu is not None:
        data["gpu"] = gpu
    return data


class Handler(BaseHTTPRequestHandler):
    def log_message(self, *_):
        pass

    def do_GET(self):
        if self.path not in ("/metrics.json", "/"):
            self.send_response(404)
            self.end_headers()
            return
        try:
            payload = json.dumps(collect()).encode()
            self.send_response(200)
            self.send_header("Content-Type", "application/json")
            self.send_header("Content-Length", str(len(payload)))
            self.send_header("Access-Control-Allow-Origin", "*")
            self.end_headers()
            self.wfile.write(payload)
        except Exception as e:
            self.send_response(500)
            self.end_headers()
            self.wfile.write(str(e).encode())


if __name__ == "__main__":
    port = int(os.environ.get("METRICS_PORT", "9101"))
    server = HTTPServer(("127.0.0.1", port), Handler)
    print(f"metrics-agent listening on 127.0.0.1:{port}", file=sys.stderr)
    server.serve_forever()
