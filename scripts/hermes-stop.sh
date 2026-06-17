#!/usr/bin/env bash
# scripts/hermes-stop.sh — Graceful Hermes shutdown with memory sync
# Usage: ./hermes-stop.sh or called by systemd before stopping Hermes
set -euo pipefail

# Find repo directory - support both direct invocation and systemd
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="${REPO_DIR:-$(dirname "$SCRIPT_DIR")}"

echo "[hermes-stop] Syncing memory before shutdown..."
# Run sync in foreground to ensure completion before stop, pass REPO_DIR
REPO_DIR="$REPO_DIR" bash "$REPO_DIR/memory/sync.sh"

echo "[hermes-stop] Stopping Hermes container..."
cd "$REPO_DIR"
docker compose stop hermes

echo "[hermes-stop] Memory synced and Hermes stopped."