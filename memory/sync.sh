#!/usr/bin/env bash
# memory/sync.sh — Sync Hermes memory to GitHub repository
# Called by cron every 30 minutes and on graceful stop
set -euo pipefail

REPO_DIR="${REPO_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
MEMORY_REPO_DIR="$REPO_DIR/memory"

# Source environment for GitHub credentials
set -a
source "$REPO_DIR/.env"
set +a

HERMES_HOME="$HOME/.hermes"
SYNC_DIR="$HERMES_HOME/memory-sync"

# ── Ensure sync directory exists and is a git repo ─────────────
if [[ ! -d "$SYNC_DIR/.git" ]]; then
    echo "[sync] Initializing memory sync repository..."
    mkdir -p "$SYNC_DIR"
    git clone "$GITHUB_MEMORY_REPO" "$SYNC_DIR" --depth=1
fi

cd "$SYNC_DIR"

# ── Export sessions from state.db ─────────────────────────────────
if [[ -f "$HERMES_HOME/state.db" ]]; then
    echo "[sync] Exporting sessions from state.db..."
    python3 "$REPO_DIR/memory/export_sessions.py" "$HERMES_HOME/state.db" "$SYNC_DIR"
fi

# ── Export shared memory ────────────────────────────────────────
if [[ -f "$HERMES_HOME/MEMORY.md" ]]; then
    echo "[sync] Updating shared MEMORY.md..."
    cp "$HERMES_HOME/MEMORY.md" "$SYNC_DIR/shared/" 2>/dev/null || mkdir -p "$SYNC_DIR/shared"
fi

# ── Git commit and push ───────────────────────────────────────────
git add -A

if git diff --cached --quiet; then
    echo "[sync] No changes to commit."
else
    git -c user.name="Hermes Agent" \
        -c user.email="hermes@local" \
        commit -m "Memory sync: $(date -Iseconds)"

    echo "[sync] Pushing to GitHub..."
    git push origin main
    echo "[sync] ✓ Sync complete."
fi