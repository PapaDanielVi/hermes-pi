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

# ── Check health via `hermes doctor` ─────────────────────────────
# Port 8642 only serves /health when the OpenAI-compatible API server is
# explicitly enabled (API_SERVER_ENABLED=1); this Telegram-only deployment
# never sets that, so nothing ever listens there and curl-polling it just
# burns the full timeout. `hermes doctor` (bundled in the image) checks
# config, dependencies, and provider connectivity instead, and is what's
# actually available to check.
info "Checking Hermes health with 'hermes doctor'..."
doctor_output=""
doctor_ok=0
for i in {1..15}; do
    if doctor_output="$(docker compose exec -T hermes hermes doctor 2>&1)"; then
        info "✓ Hermes is healthy and running"
        doctor_ok=1
        break
    fi
    sleep 2
done

if [[ "$doctor_ok" -eq 0 ]]; then
    warn "'hermes doctor' reported issues:"
    while IFS= read -r line; do warn "  $line"; done <<< "$doctor_output"
    warn "Check logs with: docker compose logs hermes"
    warn "Re-check anytime with: docker exec -it hermes hermes doctor"
fi

info "✓ Hermes started."
