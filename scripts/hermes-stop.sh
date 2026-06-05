#!/usr/bin/env bash
# scripts/hermes-stop.sh — Stop Hermes and sync memory to GitHub
set -euo pipefail

REPO_DIR="${REPO_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"

echo "Syncing memory before stop..."
bash "$REPO_DIR/memory/sync.sh"

echo "Stopping Hermes container..."
docker compose stop hermes

echo "Memory synced and Hermes stopped."
