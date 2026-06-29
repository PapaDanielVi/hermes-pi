#!/usr/bin/env bash
# install.sh — interactive installer for hermes-pi.
#
# Modes:
#   local   Install on the machine you are running this from (the Pi itself).
#   remote  Install on a Raspberry Pi over SSH from your laptop.
#
# Run as a regular user with sudo access, NOT as root.
#
# Usage:
#   ./install.sh                 # asks local vs remote
#   ./install.sh --local         # force local mode
#   ./install.sh --remote        # force remote mode
#   ./install.sh --local --noninteractive   # use existing .env, no prompts
set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
export REPO_DIR
LOG_TAG="hermes-pi"
# shellcheck source=scripts/lib/common.sh
source "$REPO_DIR/scripts/lib/common.sh"

# ── Parse args ────────────────────────────────────────────────
MODE=""
NONINTERACTIVE=0
for arg in "$@"; do
  case "$arg" in
    --local)          MODE="local" ;;
    --remote)         MODE="remote" ;;
    --noninteractive) NONINTERACTIVE=1 ;;
    -h|--help)
      grep '^#' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) error "Unknown argument: $arg (try --help)" ;;
  esac
done

# ── Choose mode ───────────────────────────────────────────────
if [[ -z "$MODE" ]]; then
  if [[ ! -t 0 ]]; then
    error "No mode given and no terminal to ask. Use --local or --remote."
  fi
  echo
  note "Where is Hermes being installed?"
  echo "  1) This machine is the Raspberry Pi (local)"
  echo "  2) A remote Pi over SSH (I'll ask for IP/port/user)"
  _mode_choice=""
  prompt_value "Choose 1 or 2" _mode_choice "1"
  case "$_mode_choice" in
    1) MODE="local" ;;
    2) MODE="remote" ;;
    *) error "Invalid choice: $_mode_choice" ;;
  esac
fi

# ──────────────────────────────────────────────────────────────
# LOCAL MODE
# ──────────────────────────────────────────────────────────────
run_local() {
  # Build / validate .env. Non-interactive runs just validate what is present.
  HERMES_NONINTERACTIVE="$NONINTERACTIVE" bash "$REPO_DIR/scripts/00_configure.sh"

  # Hardware / OS pre-flight (writes HERMES_MEM_LIMIT into .env).
  bash "$REPO_DIR/scripts/00_preflight.sh"

  # Load the validated config.
  set -a; source "$REPO_DIR/.env"; set +a

  local scripts=(
    "scripts/01_system_deps.sh"
    "scripts/02_hermes_init.sh"
    "scripts/03_browser_setup.sh"
    "scripts/04_hermes_start.sh"
    "scripts/05_github_memory.sh"
    "scripts/06_security_check.sh"
  )
  for script in "${scripts[@]}"; do
    info "Running $script …"
    chmod +x "$REPO_DIR/$script"
    # REPO_DIR is exported at the top, so sub-scripts inherit it.
    bash "$REPO_DIR/$script"
    info "✓ $script done"
  done

  print_summary "local"
}

# ──────────────────────────────────────────────────────────────
# REMOTE MODE
# ──────────────────────────────────────────────────────────────
run_remote() {
  require_cmd ssh "Install an SSH client first."

  # Collect config on this machine so prompting happens on the laptop.
  note "First, let's configure Hermes (this runs on your laptop)."
  bash "$REPO_DIR/scripts/00_configure.sh"

  echo
  note "Now the SSH details for the Raspberry Pi."
  prompt_value "Pi host (IP or hostname)" SSH_HOST ""
  [[ -n "$SSH_HOST" ]] || error "SSH host is required."
  prompt_value "SSH port" SSH_PORT "22"
  prompt_value "SSH user" SSH_USER "$USER"
  local default_key=""
  for k in "$HOME/.ssh/id_ed25519" "$HOME/.ssh/id_rsa"; do
    [[ -f "$k" ]] && { default_key="$k"; break; }
  done
  prompt_value "SSH private key path (blank for agent/password)" SSH_KEY "$default_key"

  local ssh_opts=(-p "$SSH_PORT" -o StrictHostKeyChecking=accept-new)
  [[ -n "$SSH_KEY" ]] && ssh_opts+=(-i "$SSH_KEY")
  local target="${SSH_USER}@${SSH_HOST}"

  info "Testing SSH connection and architecture…"
  local remote_arch
  remote_arch="$(ssh "${ssh_opts[@]}" "$target" 'uname -m' 2>/dev/null)" \
    || error "Could not SSH to $target. Check host/port/user/key."
  case "$remote_arch" in
    aarch64|arm64) info "Remote architecture OK: $remote_arch" ;;
    *) error "Remote is '$remote_arch'. A 64-bit (aarch64) Pi OS is required." ;;
  esac

  local remote_dir="hermes-pi"

  # Remove any root-owned leftovers inside the repo dir from prior failed runs
  # (e.g. a literal '~' directory created when sudo didn't expand the tilde).
  ssh "${ssh_opts[@]}" "$target" "sudo rm -rf '$remote_dir/~'" 2>/dev/null || true

  info "Copying repo and config to $target:~/$remote_dir …"
  if command -v rsync &>/dev/null; then
    rsync -az --delete \
      --exclude '.git' --exclude '__pycache__' --exclude '*.pyc' --exclude '~' \
      -e "ssh ${ssh_opts[*]}" \
      "$REPO_DIR/" "$target:$remote_dir/"
  else
    warn "rsync not found; falling back to tar over ssh."
    tar -C "$REPO_DIR" --exclude='.git' --exclude='__pycache__' -czf - . \
      | ssh "${ssh_opts[@]}" "$target" "mkdir -p '$remote_dir' && tar -C '$remote_dir' -xzf -"
  fi

  info "Running the installer on the Pi…"
  # The .env we just built was copied over, so run non-interactively there.
  ssh -t "${ssh_opts[@]}" "$target" \
    "cd '$remote_dir' && chmod +x install.sh && ./install.sh --local --noninteractive"

  print_summary "remote" "$target" "${ssh_opts[*]}"
}

# ──────────────────────────────────────────────────────────────
# Post-install guidance (adapts to what was skipped)
# ──────────────────────────────────────────────────────────────
print_summary() {
  local where="$1" target="${2:-}" ssh_opts_str="${3:-}"
  local tg_token prov_a prov_o voice_enabled
  tg_token="$(env_get "$REPO_DIR/.env" TELEGRAM_BOT_TOKEN)"
  prov_a="$(env_get "$REPO_DIR/.env" ANTHROPIC_API_KEY)"
  prov_o="$(env_get "$REPO_DIR/.env" OPENROUTER_API_KEY)"
  voice_enabled="$(env_get "$REPO_DIR/.env" HERMES_VOICE_ENABLED)"

  local prefix=""
  if [[ "$where" == "remote" ]]; then
    prefix="ssh ${ssh_opts_str} ${target} "
  fi

  echo
  info "═══════════════════════════════════════════════════"
  info "  Installation complete!"
  info ""
  if [[ "$where" == "remote" ]]; then
    info "  Hermes is installed on $target."
    info "  To manage it, SSH in first:  ssh ${ssh_opts_str} ${target}"
    info "  then cd ~/hermes-pi"
  else
    info "  Hermes is running on this machine."
  fi
  info ""
  info "  Configure the agent directly inside the container:"
  info "    docker exec -it hermes hermes config"
  info "    docker exec -it hermes bash      # plain shell fallback"
  info "  Logs:  docker compose logs -f hermes"
  info "  Browser server:  journalctl -u hermes-browser -f"
  if [[ "${voice_enabled:-1}" == "1" ]]; then
    info ""
    info "  Voice mode is on. Send a Telegram voice note to try it."
    info "  Toggle per-chat:  /voice tts (all replies), /voice on (voice-in only), /voice off"
  fi

  if [[ -z "$prov_a" && -z "$prov_o" ]]; then
    info ""
    warn "  No LLM provider was set. Add one, then restart:"
    warn "    ${prefix}docker exec -it hermes hermes config   # set provider key"
    warn "    (or re-run ./install.sh to add the key to .env)"
    warn "    docker compose restart hermes"
  fi
  if [[ -z "$tg_token" ]]; then
    info ""
    warn "  No Telegram channel was set. Add it, then restart:"
    warn "    ${prefix}docker exec -it hermes hermes config   # set Telegram bot token + users"
    warn "    (or re-run ./install.sh to add it to .env)"
    warn "    docker compose restart hermes"
  fi

  # ── Kanban board ──────────────────────────────────────────────
  info ""
  info "  Kanban board — send these from Telegram (or any gateway chat):"
  info "    /kanban list               — show all open tasks"
  info "    /kanban create \"<title>\"   — create a new task"
  info "    /kanban show <id>          — show task detail + history"

  # ── Security summary ──────────────────────────────────────────
  # 06_security_check.sh writes a count to ~/.hermes/logs/.security-findings-count.
  local _sec_count_file="$HOME/.hermes/logs/.security-findings-count"
  local _sec_count=0
  [[ -f "$_sec_count_file" ]] && _sec_count="$(cat "$_sec_count_file" 2>/dev/null || echo 0)"
  if [[ "${_sec_count:-0}" -gt 0 ]]; then
    info ""
    warn "  Security review flagged $_sec_count item(s) — see the output above, or re-run:"
    warn "    ./scripts/06_security_check.sh"
    warn "  Full report saved to:  ~/.hermes/logs/security-review.txt"
  fi

  info "═══════════════════════════════════════════════════"
}

case "$MODE" in
  local)  run_local ;;
  remote) run_remote ;;
  *)      error "Unknown mode: $MODE" ;;
esac
