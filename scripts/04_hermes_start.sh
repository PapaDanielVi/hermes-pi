#!/usr/bin/env bash
# scripts/04_hermes_start.sh
# Pulls Docker image and starts Hermes gateway.
set -euo pipefail

REPO_DIR="${REPO_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
info() { echo "[04_hermes_start] $*"; }
warn() { echo "[04_hermes_start] $*" >&2; }

cd "$REPO_DIR"

# ── Clean stale lock files ─────────────────────────────────────
# Lock files left by a crashed or interrupted previous run block the kanban
# dispatcher on restart. Remove them before the container starts.
sudo rm -f "$HOME/.hermes"/*.init.lock 2>/dev/null || true

# ── Pull latest Hermes image ───────────────────────────────────
info "Pulling Hermes Docker image..."
docker compose pull

# ── Start Hermes ───────────────────────────────────────────────
info "Starting Hermes gateway..."
docker compose up -d

# ── Wait for health check ───────────────────────────────────────
info "Waiting for Hermes to become healthy..."
for i in {1..30}; do
    if docker compose exec -T hermes curl -sf http://localhost:8642/health >/dev/null 2>&1; then
        info "✓ Hermes is healthy and running"
        break
    fi
    if [[ $i -eq 30 ]]; then
        warn "Hermes health check timed out. Check logs with:"
        warn "  docker compose logs hermes"
    fi
    sleep 2
done

info "✓ Hermes started."
