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

# GitHub memory backup is optional. When it is not configured, skip entirely
# rather than erroring — this lets cron and hermes-stop.sh call this script
# unconditionally regardless of whether backup is enabled.
if [[ -z "${GITHUB_MEMORY_REPO:-}" || -z "${GITHUB_TOKEN:-}" ]]; then
    echo "[sync] GitHub memory backup not configured (GITHUB_MEMORY_REPO/GITHUB_TOKEN empty) — skipping."
    exit 0
fi

# Build authenticated URL for the memory repo
MEMORY_REPO_URL=$(echo "$GITHUB_MEMORY_REPO" | sed "s|https://|https://$GITHUB_TOKEN@|")

# ── Ensure sync directory exists and is a git repo ─────────────
if [[ ! -d "$SYNC_DIR/.git" ]]; then
    echo "[sync] Initializing memory sync repository..."
    if [[ -d "$SYNC_DIR" ]]; then
        rm -rf "$SYNC_DIR"
    fi
    mkdir -p "$SYNC_DIR"
    cd "$SYNC_DIR"
    git init
    git remote add origin "$MEMORY_REPO_URL"

    if git ls-remote --exit-code --heads origin main &>/dev/null; then
        git fetch origin main --depth=1
        git checkout -b main origin/main
    else
        # Remote is empty: seed structure and push so future syncs have a base.
        mkdir -p shared users
        printf '# Hermes Agent Memory\n' > shared/MEMORY.md
        printf '# Hermes Skills\n' > shared/skills.md
        git add -A
        git -c user.name="Hermes Agent" -c user.email="hermes@local" \
            commit -m "Initial memory repository structure"
        git branch -M main
        git push -u origin main
    fi
else
    echo "[sync] Memory sync repository already initialized, pulling latest..."
    cd "$SYNC_DIR"
    git pull origin main --depth=1 2>/dev/null || true
fi

cd "$SYNC_DIR"

# ── Export sessions from state.db ─────────────────────────────────
if [[ -f "$HERMES_HOME/state.db" ]]; then
    echo "[sync] Exporting sessions from state.db..."
    # Non-fatal: a state.db schema change must not block the skills/memory
    # push that follows.
    python3 "$REPO_DIR/memory/export_sessions.py" "$HERMES_HOME/state.db" "$SYNC_DIR" \
        || echo "[sync] Session export failed, continuing without it."
fi

# ── Export shared memory ────────────────────────────────────────
# Hermes writes curated memory under $HERMES_HOME/memories/ (MEMORY.md and
# USER.md), not as flat files directly in $HERMES_HOME.
mkdir -p "$SYNC_DIR/shared"
if [[ -f "$HERMES_HOME/memories/MEMORY.md" ]]; then
    echo "[sync] Updating shared MEMORY.md..."
    cp "$HERMES_HOME/memories/MEMORY.md" "$SYNC_DIR/shared/MEMORY.md"
fi
if [[ -f "$HERMES_HOME/memories/USER.md" ]]; then
    echo "[sync] Updating shared USER.md..."
    cp "$HERMES_HOME/memories/USER.md" "$SYNC_DIR/shared/USER.md"
fi

# ── Export skills ──────────────────────────────────────────────
# Agent-created skills always land in $HERMES_HOME/skills/. Mirror the actual
# files (not just a generated index) so they are recoverable from GitHub.
if [[ -d "$HERMES_HOME/skills" ]]; then
    echo "[sync] Updating shared skills..."
    mkdir -p "$SYNC_DIR/shared/skills"
    rsync -a --delete "$HERMES_HOME/skills/" "$SYNC_DIR/shared/skills/" 2>/dev/null \
        || cp -r "$HERMES_HOME/skills/." "$SYNC_DIR/shared/skills/"

    {
        echo "# Hermes Skills"
        echo
        (
            shopt -s nullglob
            cd "$HERMES_HOME/skills" && for f in *.md; do echo "- $f"; done | sort
        )
    } > "$SYNC_DIR/shared/skills.md"
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