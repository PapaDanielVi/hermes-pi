#!/usr/bin/env bash
# scripts/04_hermes_start.sh
# Pulls Docker image, starts Hermes gateway, and (when enabled) installs the
# Antigravity CLI (agy) and hermes-antigravity-oauth plugin into ~/.hermes.
set -euo pipefail

REPO_DIR="${REPO_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
LOG_TAG="04_hermes_start"
# shellcheck source=scripts/lib/common.sh
source "$REPO_DIR/scripts/lib/common.sh"

set -a; source "$REPO_DIR/.env"; set +a

ANTIGRAVITY_PLUGIN_REPO="https://github.com/neerazz/hermes-antigravity-oauth"
ANTIGRAVITY_INSTALLER_URL="https://antigravity.google/cli/install.sh"

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

# ── Optional: Google Antigravity OAuth provider (agy + plugin) ─
antigravity_signed_in=0
if [[ "${HERMES_ANTIGRAVITY_ENABLED:-0}" == "1" ]]; then
    info "Waiting for Hermes container bootstrap..."
    container_ready=0
    for _ in {1..15}; do
        if docker compose exec -T hermes hermes --version >/dev/null 2>&1; then
            container_ready=1
            break
        fi
        sleep 2
    done
    if [[ "$container_ready" -eq 0 ]]; then
        error "Hermes container did not become ready in time. Check: docker compose logs hermes"
    fi

    # Install Google's official agy binary into /opt/data/.local/bin (mounted
    # from ~/.hermes/.local/bin), which is already on PATH inside the image and
    # survives image updates (`docker compose pull && docker compose up -d`).
    if [[ ! -x "$HOME/.hermes/.local/bin/agy" ]]; then
        info "Installing Antigravity CLI (agy) into ~/.hermes/.local/bin..."
        docker compose exec -T -u hermes -e HOME=/opt/data hermes bash -c "
            set -euo pipefail
            tmp=\"\$(mktemp)\"
            trap 'rm -f \"\$tmp\"' EXIT
            curl -fsSL '${ANTIGRAVITY_INSTALLER_URL}' -o \"\$tmp\"
            bash \"\$tmp\" --dir /opt/data/.local/bin
        "
    else
        info "Antigravity CLI (agy) already installed."
    fi
    agy_version="$(docker compose exec -T -u hermes -e HOME=/opt/data hermes agy --version 2>/dev/null | head -n1 || true)"
    if [[ -z "$agy_version" ]]; then
        error "Antigravity CLI (agy) failed to run inside the container."
    fi
    info "Antigravity CLI ready: $agy_version"

    # Install and enable the hermes-antigravity-oauth plugin in /opt/data/plugins.
    # Prefer the curated catalog name `antigravity-oauth` so Hermes uses the
    # human-reviewed pin (accepted non-interactively by Plugin Guard) and pass
    # --yes-deps so headless installs do not trip the non-interactive consent gate.
    if [[ ! -f "$HOME/.hermes/plugins/antigravity-oauth/plugin.yaml" ]]; then
        info "Installing antigravity-oauth plugin from Hermes catalog..."
        if ! docker compose exec -T hermes hermes plugins install antigravity-oauth --enable --yes-deps; then
            warn "Catalog install failed; retrying from $ANTIGRAVITY_PLUGIN_REPO..."
            docker compose exec -T hermes hermes plugins install "$ANTIGRAVITY_PLUGIN_REPO" --enable --yes-deps --force
        fi
    else
        info "antigravity-oauth plugin already installed; ensuring it is enabled..."
        docker compose exec -T hermes hermes plugins enable antigravity-oauth
    fi

    # Restart so the gateway loads the newly installed plugin and agy binary.
    info "Restarting Hermes gateway to load antigravity-oauth..."
    docker compose restart hermes
    for _ in {1..15}; do
        if docker compose exec -T hermes hermes --version >/dev/null 2>&1; then
            break
        fi
        sleep 2
    done

    auth_status_out="$(docker compose exec -T hermes hermes auth status antigravity-oauth 2>&1 || true)"
    if grep -qi "Unknown provider" <<< "$auth_status_out"; then
        error "antigravity-oauth plugin did not register with Hermes: $auth_status_out"
    elif grep -qi "logged in" <<< "$auth_status_out"; then
        antigravity_signed_in=1
        info "Antigravity OAuth session is active."
    else
        note "Antigravity OAuth is not signed in yet. Run the one-time login after install:"
        note "  docker exec -it hermes hermes auth add antigravity-oauth"
    fi
fi

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
if [[ "${HERMES_ANTIGRAVITY_ENABLED:-0}" == "1" && "$antigravity_signed_in" -eq 0 ]]; then
    if doctor_output="$(docker compose exec -T hermes hermes doctor 2>&1)"; then
        info "✓ Hermes is healthy and running"
        doctor_ok=1
    else
        warn "'hermes doctor' reported issues (auth warnings are expected until you sign in to Antigravity):"
        while IFS= read -r line; do warn "  $line"; done <<< "$doctor_output"
        warn "Sign in with: docker exec -it hermes hermes auth add antigravity-oauth"
        warn "Then re-check with: docker exec -it hermes hermes doctor"
    fi
else
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
fi

info "✓ Hermes started."
