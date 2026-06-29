#!/usr/bin/env bash
# scripts/03_browser_setup.sh
# Installs Playwright dependencies, playwright-stealth, and starts browser service
set -euo pipefail

REPO_DIR="${REPO_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
LOG_TAG="03_browser_setup"
# shellcheck source=scripts/lib/common.sh
source "$REPO_DIR/scripts/lib/common.sh"

# Pick up a port override from .env so the service matches config.yaml.
BROWSER_SERVER_PORT="$(env_get "$REPO_DIR/.env" BROWSER_SERVER_PORT)"
BROWSER_SERVER_PORT="${BROWSER_SERVER_PORT:-5555}"

# ── Ensure uv is installed ───────────────────────────────────────
if ! command -v uv &>/dev/null; then
  info "Installing uv..."
  curl -LsSf https://astral.sh/uv/install.sh | sudo UV_INSTALL_DIR=/usr/local/bin sh
fi

VENV_DIR="/opt/hermes-pi/venv"

# ── Create virtual environment ────────────────────────────────────
info "Creating Python virtual environment at $VENV_DIR..."
sudo mkdir -p /opt/hermes-pi
sudo uv venv --clear "$VENV_DIR"

# ── Install Python dependencies ───────────────────────────────────
info "Installing Python dependencies with uv..."
sudo uv pip install --python "$VENV_DIR/bin/python" -q -r "$REPO_DIR/browser/requirements.txt"

# ── Install Playwright browsers ─────────────────────────────────
info "Installing Playwright Chromium..."
sudo "$VENV_DIR/bin/playwright" install chromium --with-deps

# ── Install browser to system location ────────────────────────────
info "Installing browser files to /opt/hermes-pi..."
sudo mkdir -p /opt/hermes-pi/browser
sudo cp "$REPO_DIR/browser/browser_server.py" /opt/hermes-pi/browser/
sudo cp "$REPO_DIR/browser/requirements.txt" /opt/hermes-pi/browser/

# ── Copy and configure systemd service file ─────────────────────────
info "Installing systemd service..."
SERVICE_FILE="$REPO_DIR/browser/browser.service"
# Replace placeholders with the actual repo location and browser port.
sudo mkdir -p /etc/systemd/system
sudo sed \
  -e "s|{{REPO_DIR}}|$REPO_DIR|g" \
  -e "s|{{BROWSER_SERVER_PORT}}|$BROWSER_SERVER_PORT|g" \
  "$SERVICE_FILE" | sudo tee /etc/systemd/system/hermes-browser.service > /dev/null

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
