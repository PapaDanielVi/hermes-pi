#!/usr/bin/env bash
# scripts/00_preflight.sh
# Hardware and OS pre-flight checks. Requires 64-bit (aarch64) and a Debian-family
# (apt) system, then detects the Pi model and total RAM to pick a memory limit.
set -euo pipefail

REPO_DIR="${REPO_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
LOG_TAG="00_preflight"
# shellcheck source=scripts/lib/common.sh
source "$REPO_DIR/scripts/lib/common.sh"

ENV_FILE="$REPO_DIR/.env"

# ── Architecture: require 64-bit ARM ──────────────────────────
ARCH="$(uname -m)"
case "$ARCH" in
  aarch64|arm64)
    info "Architecture OK: $ARCH"
    ;;
  armv7l|armv6l|armhf)
    error "32-bit OS detected ($ARCH). Hermes and Playwright Chromium need a 64-bit OS.
       Reflash with Raspberry Pi OS (64-bit) or Ubuntu Server arm64, then re-run."
    ;;
  *)
    warn "Unexpected architecture '$ARCH'. This installer targets 64-bit ARM (Pi 4/5)."
    warn "Continuing, but packages may not match."
    ;;
esac

# ── Package manager: require apt (Debian family) ──────────────
if ! command -v apt-get &>/dev/null; then
  error "No 'apt' found. This installer supports Debian-family Linux only
       (Raspberry Pi OS, Ubuntu, Debian). Detected something else."
fi
info "Package manager OK: apt"

# ── Detect Pi model (informational) ───────────────────────────
PI_MODEL="unknown"
if [[ -r /proc/device-tree/model ]]; then
  # The model string is NUL-terminated; strip the trailing NUL.
  PI_MODEL="$(tr -d '\0' < /proc/device-tree/model)"
elif [[ -r /proc/cpuinfo ]]; then
  PI_MODEL="$(grep -m1 -i 'model' /proc/cpuinfo | cut -d: -f2- | sed 's/^ *//')"
fi
info "Detected board: $PI_MODEL"

# ── Detect total RAM and pick a Hermes memory limit ───────────
# Read total RAM in kB from /proc/meminfo and convert to MB.
RAM_KB="$(awk '/^MemTotal:/ {print $2}' /proc/meminfo 2>/dev/null || echo 0)"
RAM_MB=$(( RAM_KB / 1024 ))
info "Total RAM: ${RAM_MB} MB"

# Leave headroom for the browser server (Chromium) and the OS.
if   (( RAM_MB >= 7000 )); then MEM_LIMIT="3G"     # 8 GB Pi 5
elif (( RAM_MB >= 3500 )); then MEM_LIMIT="2500M"  # 4 GB Pi 4/5
elif (( RAM_MB >= 1700 )); then MEM_LIMIT="1500M"  # 2 GB Pi 4
else
  MEM_LIMIT="1200M"
  warn "Low RAM (${RAM_MB} MB). Performance will be limited; 4 GB or more recommended."
fi

# Only write the default if the user has not pinned one already.
EXISTING="$(env_get "$ENV_FILE" HERMES_MEM_LIMIT)"
if [[ -z "$EXISTING" ]]; then
  env_set "$ENV_FILE" HERMES_MEM_LIMIT "$MEM_LIMIT"
  info "Set HERMES_MEM_LIMIT=$MEM_LIMIT in .env"
else
  info "HERMES_MEM_LIMIT already set to '$EXISTING' — keeping it."
fi

# ── Record host UID/GID for docker-compose user: mapping ─────
# docker-compose passes these to the container so it runs as the same user
# as the host. This means files created in ~/.hermes (mounted as /opt/data)
# are owned by the host user — no special permissions needed on the volume.
env_set "$ENV_FILE" HOST_UID "$(id -u)"
env_set "$ENV_FILE" HOST_GID "$(id -g)"
info "Set HOST_UID=$(id -u) HOST_GID=$(id -g) in .env"

info "✓ Pre-flight checks passed."
