#!/usr/bin/env bash
# install.sh — one-shot installer for hermes-pi
# Run as a regular user (with sudo access), NOT as root.
# Usage: ./install.sh

set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# ── Colour helpers ────────────────────────────────────────────
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; NC='\033[0m'
info()  { echo -e "${GREEN}[hermes-pi]${NC} $*"; }
warn()  { echo -e "${YELLOW}[hermes-pi]${NC} $*"; }
error() { echo -e "${RED}[hermes-pi]${NC} $*" >&2; exit 1; }

# ── Pre-flight checks ─────────────────────────────────────────
[[ -f "$REPO_DIR/.env" ]] || error ".env not found. Copy .env.example to .env and fill it in."
[[ $(uname -m) == "aarch64" ]] || warn "Not running on ARM64 — some packages may differ."

# Source .env for validation
# shellcheck disable=SC1091
set -a; source "$REPO_DIR/.env"; set +a

[[ -n "${TELEGRAM_BOT_TOKEN:-}"    ]] || error "TELEGRAM_BOT_TOKEN is empty in .env"
[[ -n "${TELEGRAM_ALLOWED_USERS:-}" ]] || error "TELEGRAM_ALLOWED_USERS is empty in .env"
[[ -n "${GITHUB_TOKEN:-}"          ]] || error "GITHUB_TOKEN is empty in .env"
[[ -n "${GITHUB_MEMORY_REPO:-}"    ]] || error "GITHUB_MEMORY_REPO is empty in .env"

info "All required variables found. Starting installation…"

# ── Run sub-scripts ────────────────────────────────────────────
SCRIPTS=(
  "scripts/01_system_deps.sh"
  "scripts/02_hermes_init.sh"
  "scripts/03_browser_setup.sh"
  "scripts/04_hermes_start.sh"
  "scripts/05_github_memory.sh"
)

for script in "${SCRIPTS[@]}"; do
  info "Running $script …"
  chmod +x "$REPO_DIR/$script"
  # Pass REPO_DIR so sub-scripts can reference project files
  REPO_DIR="$REPO_DIR" bash "$REPO_DIR/$script"
  info "✓ $script done"
done

info "═══════════════════════════════════════════════════"
info "  Installation complete!"
info ""
info "  Hermes is running. Message your Telegram bot now."
info "  Logs: docker compose logs -f hermes"
info "  Browser server: journalctl -u hermes-browser -f"
info "═══════════════════════════════════════════════════"
