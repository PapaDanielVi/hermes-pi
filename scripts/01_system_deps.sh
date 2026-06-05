#!/usr/bin/env bash
# scripts/01_system_deps.sh
# Installs: Docker, Docker Compose, Python 3.11, uv, Chromium, Xvfb, git, jq, curl
set -euo pipefail

info() { echo "[01_system_deps] $*"; }

info "Updating package lists…"
sudo apt update -qq

info "Installing base packages…"
sudo apt install -y --no-install-recommends \
  git curl wget jq ca-certificates gnupg lsb-release \
  python3 python3-pip python3-venv \
  xvfb \
  chromium-browser \
  fonts-liberation fonts-noto-cjk \
  sqlite3 \
  2>/dev/null

# ── Install uv system-wide ─────────────────────────────────────
if ! command -v uv &>/dev/null; then
  info "Installing uv system-wide..."
  sudo curl -LsSf https://astral.sh/uv/install.sh | sudo sh -s -- --install-dir /usr/local/bin
else
  info "uv already installed: $(uv --version)"
fi

# ── Docker ─────────────────────────────────────────────────────
if ! command -v docker &>/dev/null; then
  info "Installing Docker…"
  curl -fsSL https://get.docker.com | sh
  sudo usermod -aG docker "$USER"
  info "Docker installed. NOTE: you may need to log out and back in for group membership."
else
  info "Docker already installed: $(docker --version)"
fi

# ── Docker Compose plugin ─────────────────────────────────────
if ! docker compose version &>/dev/null 2>&1; then
  info "Installing Docker Compose plugin…"
  ARCH=$(uname -m)
  COMPOSE_VERSION=$(curl -s https://api.github.com/repos/docker/compose/releases/latest \
    | grep '"tag_name"' | cut -d'"' -f4)
  sudo mkdir -p /usr/local/lib/docker/cli-plugins
  sudo curl -SL \
    "https://github.com/docker/compose/releases/download/${COMPOSE_VERSION}/docker-compose-linux-${ARCH}" \
    -o /usr/local/lib/docker/cli-plugins/docker-compose
  sudo chmod +x /usr/local/lib/docker/cli-plugins/docker-compose
else
  info "Docker Compose already installed: $(docker compose version --short)"
fi

# ── Verify Chromium ARM64 ─────────────────────────────────────
CHROMIUM_BIN=$(command -v chromium-browser || command -v chromium || true)
if [[ -z "$CHROMIUM_BIN" ]]; then
  error "chromium-browser not found after install. Check apt sources."
fi
info "Chromium found at: $CHROMIUM_BIN"
"$CHROMIUM_BIN" --version

info "✓ System dependencies ready."
