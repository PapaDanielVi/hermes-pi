#!/usr/bin/env bash
# scripts/02_hermes_init.sh
# Creates ~/.hermes, applies config template, copies skill file, and installs .gitignore.
# Re-running is safe: config.yaml is only regenerated when .env values or templates change.
set -euo pipefail

REPO_DIR="${REPO_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
LOG_TAG="02_hermes_init"
# shellcheck source=scripts/lib/common.sh
source "$REPO_DIR/scripts/lib/common.sh"

HERMES_HOME="$HOME/.hermes"
sudo mkdir -p "$HERMES_HOME/skills"
sudo mkdir -p "$HERMES_HOME/logs"
sudo mkdir -p "$HERMES_HOME/plugins"
sudo chown -R "$USER:$USER" "$HERMES_HOME"

# Source .env so we can read all config values in one place.
set -a; source "$REPO_DIR/.env"; set +a

# ── Hash-gated config.yaml generation ────────────────────────
# A hash over the config-relevant .env values and both templates gates whether we
# regenerate config.yaml. This means re-running the installer is a no-op unless
# something that actually affects the config has changed.
CONFIG_FILE="$HERMES_HOME/config.yaml"
HASH_FILE="$HERMES_HOME/.config.hash"

_config_inputs() {
  # Emit the values that matter for config.yaml so sha256sum can fingerprint them.
  echo "${TELEGRAM_BOT_TOKEN:-}"
  echo "${TELEGRAM_ALLOWED_USERS:-}"
  echo "${BROWSER_SERVER_PORT:-5555}"
  echo "${HERMES_VOICE_ENABLED:-1}"
  echo "${HERMES_STT_PROVIDER:-local}"
  echo "${HERMES_STT_MODEL:-base}"
  echo "${HERMES_TTS_PROVIDER:-edge}"
  echo "${HERMES_TTS_VOICE:-en-US-AriaNeural}"
  echo "${OPENROUTER_MODEL:-poolside/laguna-m.1:free}"
  cat "$REPO_DIR/config/config.yaml.template"
  cat "$REPO_DIR/config/voice.yaml.template"
}

current_hash="$(_config_inputs | sha256sum | awk '{print $1}')"
stored_hash="$(cat "$HASH_FILE" 2>/dev/null || echo "")"

if [[ ! -f "$CONFIG_FILE" || -z "$stored_hash" || "$current_hash" != "$stored_hash" ]]; then
  if [[ -f "$CONFIG_FILE" ]]; then
    info "Config inputs changed — backing up config.yaml to config.yaml.bak and regenerating…"
    cp "$CONFIG_FILE" "$HERMES_HOME/config.yaml.bak"
  else
    info "Writing config.yaml from template…"
  fi

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
    -e "s|{{OPENROUTER_MODEL}}|${OPENROUTER_MODEL:-poolside/laguna-m.1:free}|g" \
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

  echo "$current_hash" > "$HASH_FILE"
  info "✓ config.yaml written and hash saved."
else
  info "config.yaml is up to date — skipping (no .env or template changes detected)."
fi

# ── Copy browser skill file ───────────────────────────────────
SKILL_DEST="$HERMES_HOME/skills/browser-search.md"
SKILL_SRC="$REPO_DIR/config/skill-browser.md"
if ! cmp -s "$SKILL_SRC" "$SKILL_DEST" 2>/dev/null; then
  cp "$SKILL_SRC" "$SKILL_DEST"
  info "Browser skill installed at $SKILL_DEST"
else
  info "Browser skill already up to date — skipping."
fi

# ── Install .gitignore for ~/.hermes ─────────────────────────
# Harmless on a plain directory; correct if ~/.hermes is ever git-initialised.
cp "$REPO_DIR/config/hermes-home.gitignore" "$HERMES_HOME/.gitignore"
info "~/.hermes/.gitignore installed."

# ── Secure permissions on Hermes home ────────────────────────
chmod 700 "$HERMES_HOME"
info "~/.hermes permissions set to 700."

info "✓ Hermes home initialised."
