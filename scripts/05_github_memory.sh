#!/usr/bin/env bash
# scripts/05_github_memory.sh
# Configures git credentials and installs cron job for memory sync
set -euo pipefail

REPO_DIR="${REPO_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
LOG_TAG="05_github_memory"
# shellcheck source=scripts/lib/common.sh
source "$REPO_DIR/scripts/lib/common.sh"

# ── Source .env for credentials ─────────────────────────────────
set -a; source "$REPO_DIR/.env"; set +a

MEMORY_SYNC_DIR="$REPO_DIR/memory"

# ── Configure git for memory sync ────────────────────────────────
info "Configuring git for memory repository..."

# Store credentials for the memory repo using the token
# Format: https://TOKEN@github.com/owner/repo.git
MEMORY_REPO_URL=$(echo "$GITHUB_MEMORY_REPO" | sed "s|https://|https://$GITHUB_TOKEN@|")

# Set up local cache of the memory repo.
# If the remote is empty (freshly created on GitHub), seed it with the initial
# directory structure and push. Otherwise pull existing content.
SYNC_CACHE="$HOME/.hermes/memory-repo-cache"
if [[ ! -d "$SYNC_CACHE/.git" ]]; then
    info "Setting up memory repo cache..."
    sudo rm -rf "$SYNC_CACHE"
    sudo mkdir -p "$SYNC_CACHE"
    sudo chown -R "$USER:$USER" "$HOME/.hermes"
    cd "$SYNC_CACHE"
    git init -b main
    # Set identity locally so the operator's global git config is never touched.
    git config user.name "Hermes Agent"
    git config user.email "hermes@local"
    git remote add origin "$MEMORY_REPO_URL"

    if git ls-remote --exit-code --heads origin main &>/dev/null; then
        info "Remote has commits, pulling..."
        git fetch origin main --depth 1
        git checkout -b main origin/main
    else
        info "Remote is empty, seeding initial structure and pushing..."
        mkdir -p shared users
        printf '# Hermes Agent Memory\n' > shared/MEMORY.md
        printf '# Hermes Skills\n' > shared/skills.md
        git add -A
        git -c user.name="Hermes Agent" -c user.email="hermes@local" \
            commit -m "Initial memory repository structure"
        if ! git push -u origin main 2>&1; then
            warn "Failed to push to $GITHUB_MEMORY_REPO."
            warn "Check that GITHUB_TOKEN has 'Contents: Read and write' permission on that repo."
            warn "The local cache is ready; the push can be retried by re-running this script."
        fi
    fi
    cd - > /dev/null
fi

# Ensure ~/.hermes is fully owned by the current user (guards against sudo
# leftovers from earlier install attempts).
sudo chown -R "$USER:$USER" "$HOME/.hermes"

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
