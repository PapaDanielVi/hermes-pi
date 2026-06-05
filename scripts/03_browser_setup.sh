#!/usr/bin/env bash
# scripts/03_browser_setup.sh
# Installs Playwright dependencies, playwright-stealth, and starts browser service
set -euo pipefail

REPO_DIR="${REPO_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
info() { echo "[03_browser_setup] $*"; }

# ── Ensure uv is installed ───────────────────────────────────────
if ! command -v uv &>/dev/null; then
  info "Installing uv..."
  sudo curl -LsSf https://astral.sh/uv/install.sh | sudo sh -s -- --install-dir /usr/local/bin
fi

# ── Install Python dependencies with uv ───────────────────────────
info "Installing Python dependencies with uv..."
uv pip install --system -q -r "$REPO_DIR/browser/requirements.txt"

# ── Install Playwright browsers ─────────────────────────────────
info "Installing Playwright Chromium..."
uv run --no-project playwright install chromium --with-deps

# ── Copy systemd service file ───────────────────────────────────
info "Installing systemd service..."
SERVICE_FILE="$REPO_DIR/browser/browser.service"
sudo cp "$SERVICE_FILE" /etc/systemd/system/hermes-browser.service

# Enable and start service
sudo systemctl daemon-reload
sudo systemctl enable hermes-browser.service
sudo systemctl start hermes-browser.service

# ── Verify service ────────────────────────────────────────────────
sleep 2
if systemctl is-active --quiet hermes-browser.service; then
    info "✓ Browser service started successfully"
else
    info "⚠ Browser service may not have started. Check logs:"
    info "  journalctl -u hermes-browser -f"
fi

info "✓ Browser setup complete."
