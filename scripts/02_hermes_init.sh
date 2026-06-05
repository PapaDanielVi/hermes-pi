#!/usr/bin/env bash
# scripts/02_hermes_init.sh
# Creates ~/.hermes, applies config template, copies skill file.
set -euo pipefail

REPO_DIR="${REPO_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
info() { echo "[02_hermes_init] $*"; }

HERMES_HOME="$HOME/.hermes"
mkdir -p "$HERMES_HOME/skills"
mkdir -p "$HERMES_HOME/logs"

# ── Copy config template if no config exists ──────────────────
CONFIG_FILE="$HERMES_HOME/config.yaml"
if [[ ! -f "$CONFIG_FILE" ]]; then
  info "Writing config.yaml from template…"
  # Source .env so we can substitute variables
  set -a; source "$REPO_DIR/.env"; set +a

  sed \
    -e "s|{{TELEGRAM_BOT_TOKEN}}|${TELEGRAM_BOT_TOKEN}|g" \
    -e "s|{{TELEGRAM_ALLOWED_USERS}}|${TELEGRAM_ALLOWED_USERS}|g" \
    -e "s|{{BROWSER_SERVER_PORT}}|${BROWSER_SERVER_PORT:-5555}|g" \
    "$REPO_DIR/config/config.yaml.template" > "$CONFIG_FILE"
else
  info "config.yaml already exists — skipping overwrite."
fi

# ── Copy browser skill file ───────────────────────────────────
SKILL_DEST="$HERMES_HOME/skills/browser-search.md"
cp "$REPO_DIR/config/skill-browser.md" "$SKILL_DEST"
info "Browser skill installed at $SKILL_DEST"

# ── Secure permissions on Hermes home ────────────────────────
chmod 700 "$HERMES_HOME"
info "~/.hermes permissions set to 700."

info "✓ Hermes home initialised."
