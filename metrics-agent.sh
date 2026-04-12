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
INSTALL_DIR="/usr/local/lib/ssh-metrics"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_RAW="https://raw.githubusercontent.com/chunzhimoe/cfbash/main"

install_service() {
  mkdir -p "$INSTALL_DIR"

  # Use local file if present, otherwise download
  if [[ -f "$SCRIPT_DIR/metrics_server.py" ]]; then
    cp "$SCRIPT_DIR/metrics_server.py" "$INSTALL_DIR/metrics_server.py"
  else
    curl -fsSL "${REPO_RAW}/metrics_server.py" -o "$INSTALL_DIR/metrics_server.py"
  fi
  chmod +x "$INSTALL_DIR/metrics_server.py"

  # Verify python3 works
  if ! python3 "$INSTALL_DIR/metrics_server.py" --help &>/dev/null; then
    python3 -c "print('python3 OK')" || { echo "ERROR: python3 not found"; exit 1; }
  fi

  cat > /etc/systemd/system/ssh-metrics.service <<EOF
[Unit]
Description=SSH Console Metrics Agent
After=network.target
Wants=network.target

[Service]
Type=simple
ExecStart=/usr/bin/python3 ${INSTALL_DIR}/metrics_server.py
Restart=on-failure
RestartSec=5
Environment=METRICS_PORT=${METRICS_PORT}
StandardOutput=journal
StandardError=journal

[Install]
WantedBy=multi-user.target
EOF

  systemctl daemon-reload
  systemctl enable --now ssh-metrics.service

  echo ""
  echo "✓ ssh-metrics.service installed and started on port ${METRICS_PORT}"
  echo "  Test: curl http://localhost:${METRICS_PORT}/metrics.json"
  echo ""
  systemctl status ssh-metrics.service --no-pager || true
}

case "${1:-start}" in
  install)
    install_service
    ;;
  start)
    if [[ ! -f "$INSTALL_DIR/metrics_server.py" ]]; then
      mkdir -p "$INSTALL_DIR"
      if [[ -f "$SCRIPT_DIR/metrics_server.py" ]]; then
        cp "$SCRIPT_DIR/metrics_server.py" "$INSTALL_DIR/metrics_server.py"
      else
        curl -fsSL "${REPO_RAW}/metrics_server.py" -o "$INSTALL_DIR/metrics_server.py"
      fi
      chmod +x "$INSTALL_DIR/metrics_server.py"
    fi
    exec python3 "$INSTALL_DIR/metrics_server.py"
    ;;
  *)
    echo "Usage: $0 {install|start}"
    exit 1
    ;;
esac
