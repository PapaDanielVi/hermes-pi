#!/usr/bin/env bash
# memory/cron_setup.sh — Install cron job for GitHub memory sync
# Runs every 30 minutes
set -euo pipefail

REPO_DIR="${REPO_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
SYNC_SCRIPT="$REPO_DIR/memory/sync.sh"

# ── Ensure sync script is executable ─────────────────────────────
chmod +x "$SYNC_SCRIPT"

# ── Create cron entry ───────────────────────────────────────────
CRON_ENTRY="*/30 * * * * cd $REPO_DIR && bash $SYNC_SCRIPT >> $HOME/.hermes/logs/sync.log 2>&1"

# Remove existing entry if present
(crontab -l 2>/dev/null | grep -v "memory/sync.sh") | crontab -

# Add new entry
(crontab -l 2>/dev/null; echo "$CRON_ENTRY") | crontab -

# ── Verify cron job ─────────────────────────────────────────────
echo "[cron] Installed sync job:"
crontab -l | grep sync

echo "[cron] ✓ Cron setup complete. Memory will sync every 30 minutes."