#!/usr/bin/env bash
# metrics-agent.sh — Install metrics_server.py as a systemd service
# Serves JSON at http://127.0.0.1:9101/metrics.json
#
# Usage:
#   sudo bash metrics-agent.sh install   # Install + start as systemd service
#   sudo bash metrics-agent.sh start     # Run in foreground (testing)
#
# The Python script (metrics_server.py) must be in the same directory,
# or downloadable from GitHub.

set -euo pipefail

METRICS_PORT="${METRICS_PORT:-9101}"
METRICS_HOST="${METRICS_HOST:-127.0.0.1}"
INSTALL_DIR="/usr/local/lib/ssh-metrics"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_RAW="https://raw.githubusercontent.com/chunzhimoe/cfbash/main"
PYTHON_BIN="${PYTHON_BIN:-$(command -v python3 || true)}"

ensure_python() {
  if [[ -z "$PYTHON_BIN" ]]; then
    echo "ERROR: python3 not found" >&2
    exit 1
  fi
}

install_metrics_server() {
  mkdir -p "$INSTALL_DIR"

  if [[ -f "$SCRIPT_DIR/metrics_server.py" ]]; then
    cp "$SCRIPT_DIR/metrics_server.py" "$INSTALL_DIR/metrics_server.py"
  else
    curl -fsSL "${REPO_RAW}/metrics_server.py" -o "$INSTALL_DIR/metrics_server.py"
  fi

  chmod +x "$INSTALL_DIR/metrics_server.py"
}

verify_endpoint() {
  local probe_host="$METRICS_HOST"
  if [[ "$probe_host" == "0.0.0.0" ]]; then
    probe_host="127.0.0.1"
  fi

  local url="http://${probe_host}:${METRICS_PORT}/metrics.json"
  local i

  for i in {1..10}; do
    if METRICS_URL="$url" "$PYTHON_BIN" - <<'PY' >/dev/null 2>&1
import os
import urllib.request

with urllib.request.urlopen(os.environ["METRICS_URL"], timeout=2) as response:
    if response.status != 200:
        raise SystemExit(1)
    response.read(1)
PY
    then
      echo "✓ metrics endpoint reachable: ${url}"
      return 0
    fi
    sleep 1
  done

  echo "ERROR: metrics endpoint not reachable: ${url}" >&2
  systemctl status ssh-metrics.service --no-pager || true
  return 1
}

install_service() {
  ensure_python
  install_metrics_server

  "$PYTHON_BIN" -m py_compile "$INSTALL_DIR/metrics_server.py"

  cat > /etc/systemd/system/ssh-metrics.service <<EOF
[Unit]
Description=SSH Console Metrics Agent
After=network.target
Wants=network.target

[Service]
Type=simple
ExecStart=${PYTHON_BIN} ${INSTALL_DIR}/metrics_server.py
Restart=on-failure
RestartSec=5
Environment=METRICS_HOST=${METRICS_HOST}
Environment=METRICS_PORT=${METRICS_PORT}
StandardOutput=journal
StandardError=journal

[Install]
WantedBy=multi-user.target
EOF

  systemctl daemon-reload
  systemctl enable ssh-metrics.service
  systemctl restart ssh-metrics.service
  verify_endpoint

  echo ""
  echo "✓ ssh-metrics.service installed and started on ${METRICS_HOST}:${METRICS_PORT}"
  echo "  Test: curl http://${METRICS_HOST}:${METRICS_PORT}/metrics.json"
  echo ""
  systemctl status ssh-metrics.service --no-pager || true
}

case "${1:-start}" in
  install)
    install_service
    ;;
  start)
    ensure_python
    if [[ ! -f "$INSTALL_DIR/metrics_server.py" ]]; then
      install_metrics_server
    fi
    exec "$PYTHON_BIN" "$INSTALL_DIR/metrics_server.py"
    ;;
  *)
    echo "Usage: $0 {install|start}"
    exit 1
    ;;
esac
