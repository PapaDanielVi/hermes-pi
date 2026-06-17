#!/usr/bin/env bash
# scripts/lib/common.sh — shared helpers sourced by install.sh and sub-scripts.
# Provides logging helpers and small interactive prompt helpers.
# This file is meant to be sourced, not executed directly.

# ── Colour helpers ────────────────────────────────────────────
# Only emit colour when stdout is a terminal.
if [[ -t 1 ]]; then
  C_RED='\033[0;31m'; C_GREEN='\033[0;32m'; C_YELLOW='\033[1;33m'
  C_BLUE='\033[0;34m'; C_NC='\033[0m'
else
  C_RED=''; C_GREEN=''; C_YELLOW=''; C_BLUE=''; C_NC=''
fi

# LOG_TAG lets each caller label its output, e.g. LOG_TAG="01_system_deps".
LOG_TAG="${LOG_TAG:-hermes-pi}"

info()  { echo -e "${C_GREEN}[${LOG_TAG}]${C_NC} $*"; }
warn()  { echo -e "${C_YELLOW}[${LOG_TAG}]${C_NC} $*" >&2; }
note()  { echo -e "${C_BLUE}[${LOG_TAG}]${C_NC} $*"; }
error() { echo -e "${C_RED}[${LOG_TAG}]${C_NC} $*" >&2; exit 1; }

# require_cmd <command> [hint]
# Exit with a clear message if a required command is missing.
require_cmd() {
  local cmd="$1" hint="${2:-}"
  if ! command -v "$cmd" &>/dev/null; then
    if [[ -n "$hint" ]]; then
      error "Required command '$cmd' not found. $hint"
    else
      error "Required command '$cmd' not found."
    fi
  fi
}

# prompt_value <prompt> <varname> [default]
# Read a plain value from the user. If a default is given, an empty answer keeps it.
# When stdin is not a tty, the default (or empty) is used without blocking.
prompt_value() {
  local prompt="$1" varname="$2" default="${3:-}" answer
  if [[ ! -t 0 ]]; then
    printf -v "$varname" '%s' "$default"
    return 0
  fi
  if [[ -n "$default" ]]; then
    read -r -p "$prompt [$default]: " answer
    answer="${answer:-$default}"
  else
    read -r -p "$prompt: " answer
  fi
  printf -v "$varname" '%s' "$answer"
}

# prompt_secret <prompt> <varname> [current]
# Read a hidden value. If a current value exists, show it masked and allow Enter
# to keep it. When stdin is not a tty, the current value is kept.
prompt_secret() {
  local prompt="$1" varname="$2" current="${3:-}" answer hint=""
  if [[ ! -t 0 ]]; then
    printf -v "$varname" '%s' "$current"
    return 0
  fi
  if [[ -n "$current" ]]; then
    hint=" [keep current: ${current:0:4}…]"
  fi
  read -r -s -p "${prompt}${hint}: " answer
  echo
  if [[ -z "$answer" && -n "$current" ]]; then
    answer="$current"
  fi
  printf -v "$varname" '%s' "$answer"
}

# env_set <file> <key> <value>
# Insert or replace KEY=value in an env file, creating the file if needed.
# The value is written verbatim (no quoting), matching .env conventions here.
env_set() {
  local file="$1" key="$2" value="$3" tmp
  touch "$file"
  tmp="$(mktemp "${file}.XXXXXX")"
  # Drop any existing line for this key, then append the new one.
  grep -v -E "^${key}=" "$file" > "$tmp" 2>/dev/null || true
  echo "${key}=${value}" >> "$tmp"
  mv "$tmp" "$file"
}

# env_get <file> <key>
# Echo the value for KEY from an env file, or empty if missing.
env_get() {
  local file="$1" key="$2"
  [[ -f "$file" ]] || return 0
  sed -n -E "s/^${key}=(.*)$/\1/p" "$file" | tail -n1
}

# prompt_yesno <prompt> [default:y|n]
# Returns 0 for yes, 1 for no. Non-tty falls back to the default.
prompt_yesno() {
  local prompt="$1" default="${2:-y}" answer hint
  if [[ "$default" == "y" ]]; then hint="[Y/n]"; else hint="[y/N]"; fi
  if [[ ! -t 0 ]]; then
    [[ "$default" == "y" ]]
    return $?
  fi
  read -r -p "$prompt $hint: " answer
  answer="${answer:-$default}"
  [[ "$answer" =~ ^[Yy] ]]
}
