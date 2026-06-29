#!/usr/bin/env bash
# scripts/02_hermes_init.sh
# Creates ~/.hermes, applies config template, copies skill file.
set -euo pipefail

REPO_DIR="${REPO_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
LOG_TAG="02_hermes_init"
# shellcheck source=scripts/lib/common.sh
source "$REPO_DIR/scripts/lib/common.sh"

HERMES_HOME="$HOME/.hermes"
sudo mkdir -p "$HERMES_HOME/skills"
sudo mkdir -p "$HERMES_HOME/logs"
sudo chown -R "$USER:$USER" "$HERMES_HOME"

# ── Copy config template if no config exists ──────────────────
CONFIG_FILE="$HERMES_HOME/config.yaml"
if [[ ! -f "$CONFIG_FILE" ]]; then
  info "Writing config.yaml from template…"
  # Source .env so we can substitute variables
  set -a; source "$REPO_DIR/.env"; set +a

  # The Telegram block is only written when a bot token is present, so a deferred
  # channel does not leave Hermes trying to start a gateway with an empty token.
  if [[ -n "${TELEGRAM_BOT_TOKEN:-}" ]]; then
    {
      echo "telegram:"
      echo "  bot_token: \"${TELEGRAM_BOT_TOKEN}\""
      echo "  allowed_users: \"${TELEGRAM_ALLOWED_USERS:-}\""
      echo
    } > "$CONFIG_FILE"
  else
    : > "$CONFIG_FILE"
    info "No Telegram token set — writing config.yaml without the telegram block."
  fi

  sed \
    -e "s|{{BROWSER_SERVER_PORT}}|${BROWSER_SERVER_PORT:-5555}|g" \
    "$REPO_DIR/config/config.yaml.template" >> "$CONFIG_FILE"

  # Append voice/STT/TTS config when voice mode is enabled.
  if [[ "${HERMES_VOICE_ENABLED:-1}" == "1" ]]; then
    info "Voice mode enabled — appending voice/STT/TTS config…"
    sed \
      -e "s|{{STT_PROVIDER}}|${HERMES_STT_PROVIDER:-local}|g" \
      -e "s|{{STT_MODEL}}|${HERMES_STT_MODEL:-base}|g" \
      -e "s|{{TTS_PROVIDER}}|${HERMES_TTS_PROVIDER:-edge}|g" \
      -e "s|{{TTS_VOICE}}|${HERMES_TTS_VOICE:-en-US-AriaNeural}|g" \
      "$REPO_DIR/config/voice.yaml.template" >> "$CONFIG_FILE"
  else
    info "Voice mode disabled — skipping voice config."
  fi
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
