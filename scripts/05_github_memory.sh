#!/usr/bin/env bash
# scripts/05_github_memory.sh
# Configures git credentials and installs cron job for memory sync
set -euo pipefail

REPO_DIR="${REPO_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
info() { echo "[05_github_memory] $*"; }

# ── Source .env for credentials ─────────────────────────────────
set -a; source "$REPO_DIR/.env"; set +a

MEMORY_SYNC_DIR="$REPO_DIR/memory"

# ── Configure git for memory sync ────────────────────────────────
info "Configuring git for memory repository..."

# Set git config for the bot user
git config --global user.name "Hermes Agent"
git config --global user.email "hermes@local"

# Store credentials for the memory repo using the token
# Format: https://TOKEN@github.com/owner/repo.git
MEMORY_REPO_URL=$(echo "$GITHUB_MEMORY_REPO" | sed "s|https://|https://$GITHUB_TOKEN@|")

# Test clone to cache credentials
SYNC_CACHE="$HOME/.hermes/memory-repo-cache"
if [[ ! -d "$SYNC_CACHE/.git" ]]; then
    info "Cloning memory repo to cache location..."
    rm -rf "$SYNC_CACHE"
    git clone "$MEMORY_REPO_URL" "$SYNC_CACHE" --depth 1
fi

# ── Install cron job ────────────────────────────────────────────
info "Installing memory sync cron job..."
chmod +x "$MEMORY_SYNC_DIR/cron_setup.sh"
"$MEMORY_SYNC_DIR/cron_setup.sh"

# ── Ensure HERMES_HOME exists with proper structure ───────────────
HERMES_HOME="$HOME/.hermes"
mkdir -p "$HERMES_HOME/shared"
mkdir -p "$HERMES_HOME/users"

# Initialize shared memory files if they don't exist
touch "$HERMES_HOME/shared/MEMORY.md"
touch "$HERMES_HOME/shared/skills.md"

info "✓ GitHub memory configuration complete."
info "Memory sync will run every 30 minutes."
