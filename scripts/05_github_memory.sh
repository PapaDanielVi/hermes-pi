#!/usr/bin/env bash
# scripts/05_github_memory.sh
# Configures the optional GitHub memory backup (git remote, initial sync, cron
# job) and installs the Hermes systemd service. GitHub backup is skipped
# cleanly when GITHUB_MEMORY_REPO/GITHUB_TOKEN are not set in .env — memory
# and skills then stay local to this Pi only, with no off-device copy.
set -euo pipefail

REPO_DIR="${REPO_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
LOG_TAG="05_github_memory"
# shellcheck source=scripts/lib/common.sh
source "$REPO_DIR/scripts/lib/common.sh"

# ── Source .env for credentials ─────────────────────────────────
set -a; source "$REPO_DIR/.env"; set +a

MEMORY_SYNC_DIR="$REPO_DIR/memory"

# Ensure ~/.hermes is fully owned by the current user (guards against sudo
# leftovers from earlier install attempts) before anything writes into it.
sudo chown -R "$USER:$USER" "$HOME/.hermes"

GITHUB_BACKUP_ENABLED=0
if [[ -n "${GITHUB_MEMORY_REPO:-}" && -n "${GITHUB_TOKEN:-}" ]]; then
    GITHUB_BACKUP_ENABLED=1
fi

if [[ "$GITHUB_BACKUP_ENABLED" -eq 1 ]]; then
    info "Configuring git for memory repository..."

    # memory/sync.sh is the single source of truth for the GitHub memory clone
    # (~/.hermes/memory-sync): it inits and seeds the repo on first run (or pulls
    # if it already exists), exports skills/memory/sessions, and commits+pushes.
    # It is idempotent — it never re-clones or wipes the clone once it exists, and
    # it never touches the rest of ~/.hermes. Running it here does the same job
    # the old duplicate clone-and-seed block did, with a real export instead of
    # just placeholder files.
    info "Running initial memory sync..."
    chmod +x "$MEMORY_SYNC_DIR/sync.sh"
    if ! REPO_DIR="$REPO_DIR" bash "$MEMORY_SYNC_DIR/sync.sh"; then
        warn "Initial memory sync failed. Check that GITHUB_TOKEN has 'Contents: Read and write'"
        warn "permission on $GITHUB_MEMORY_REPO. It will retry automatically via cron."
    fi
else
    info "GitHub memory backup not configured — memory and skills will stay local to this Pi."
    info "Run ./install.sh again to add a GITHUB_MEMORY_REPO/GITHUB_TOKEN and enable backup later."
fi

# ── Install and enable systemd service for boot + graceful shutdown ───
info "Installing and enabling Hermes systemd service..."
HERMES_SERVICE="$REPO_DIR/config/hermes.service"
if [[ -f "$HERMES_SERVICE" ]]; then
    sudo sed "s|{{REPO_DIR}}|$REPO_DIR|g" "$HERMES_SERVICE" | sudo tee /etc/systemd/system/hermes.service > /dev/null
    sudo systemctl daemon-reload
    # Enable so Hermes starts on boot and runs the memory sync on shutdown.
    sudo systemctl enable hermes.service
    # Mark it active now (idempotent: the container is already up from step 04)
    # so the graceful ExecStop sync also fires on this session's shutdown.
    sudo systemctl start hermes.service
    info "hermes.service enabled (auto-start on boot, memory sync on shutdown)."
else
    warn "config/hermes.service missing — skipping systemd auto-start."
fi

# ── Install cron job ────────────────────────────────────────────
if [[ "$GITHUB_BACKUP_ENABLED" -eq 1 ]]; then
    info "Installing memory sync cron job..."
    chmod +x "$MEMORY_SYNC_DIR/cron_setup.sh"
    "$MEMORY_SYNC_DIR/cron_setup.sh"
    info "✓ GitHub memory configuration complete."
    info "Memory sync will run every 30 minutes."
else
    # Remove any cron entry from a previous run where backup was enabled.
    (crontab -l 2>/dev/null | grep -v "memory/sync.sh") | crontab - 2>/dev/null || true
    info "✓ Local-only setup complete (no GitHub backup, no sync cron job)."
fi
