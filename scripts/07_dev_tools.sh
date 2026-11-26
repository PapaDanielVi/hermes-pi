#!/usr/bin/env bash
# scripts/07_dev_tools.sh
# Optional: installs GitHub CLI (gh) and the Claude Code CLI on the Pi host itself
# (never inside the hermes container), then stands up a small local MCP server
# (hermes-claude-delegate.service) so Hermes can delegate coding tasks to Claude
# Code directly from Telegram — no SSH needed for day-to-day use, only for the
# one-time gh/claude login. Skipped entirely unless HERMES_INSTALL_DEV_TOOLS=1 in
# .env. Nothing here is installed into the Hermes Docker image or a volume, so
# `docker compose pull` never touches or removes it.
set -euo pipefail

REPO_DIR="${REPO_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
LOG_TAG="07_dev_tools"
# shellcheck source=scripts/lib/common.sh
source "$REPO_DIR/scripts/lib/common.sh"

# ── Source .env ──────────────────────────────────────────────
set -a; source "$REPO_DIR/.env"; set +a

if [[ "${HERMES_INSTALL_DEV_TOOLS:-0}" != "1" ]]; then
  info "Dev tools (gh + Claude Code CLI) not requested — skipping."
  info "Run ./install.sh again to enable them later."
  exit 0
fi

CLAUDE_DELEGATE_PORT="${CLAUDE_DELEGATE_PORT:-5556}"
WORKSPACE_DIR="$HOME/coding-workspace"

# ── GitHub CLI ───────────────────────────────────────────────
if command -v gh &>/dev/null; then
  info "GitHub CLI already installed ($(gh --version | head -n1))."
else
  info "Installing GitHub CLI..."
  sudo mkdir -p -m 755 /etc/apt/keyrings
  curl -fsSL https://cli.github.com/packages/githubcli-archive-keyring.gpg \
    | sudo tee /etc/apt/keyrings/githubcli-archive-keyring.gpg > /dev/null
  sudo chmod go+r /etc/apt/keyrings/githubcli-archive-keyring.gpg
  echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/githubcli-archive-keyring.gpg] https://cli.github.com/packages stable main" \
    | sudo tee /etc/apt/sources.list.d/github-cli.list > /dev/null
  sudo apt update -qq
  sudo apt install -y gh
  info "✓ GitHub CLI installed."
fi

# ── Claude Code CLI ──────────────────────────────────────────
if command -v claude &>/dev/null; then
  info "Claude Code CLI already installed ($(claude --version 2>/dev/null | head -n1))."
else
  info "Installing Claude Code CLI..."
  curl -fsSL https://claude.ai/install.sh | bash
  info "✓ Claude Code CLI installed."
fi

# ── Workspace for delegated coding tasks ─────────────────────
mkdir -p "$WORKSPACE_DIR"
info "Coding workspace: $WORKSPACE_DIR (repos are cloned here on first use)."

# Pre-create the gh/claude credential paths so the systemd unit's
# ReadWritePaths (set up once at each service start) cover them from the very
# first start, even though the actual login happens later, by hand, after
# this script finishes.
mkdir -p "$HOME/.claude" "$HOME/.config/gh"
touch "$HOME/.claude.json"

# ── Delegate MCP server (Python venv + systemd service) ──────
DELEGATE_VENV="/opt/hermes-pi/delegate-venv"
sudo mkdir -p /opt/hermes-pi
if [[ ! -x "$DELEGATE_VENV/bin/python" ]]; then
  info "Creating Python virtual environment for the delegate server..."
  sudo uv venv "$DELEGATE_VENV"
else
  info "Delegate venv already exists — skipping creation."
fi

info "Installing delegate server dependencies..."
sudo uv pip install --python "$DELEGATE_VENV/bin/python" -q -r "$REPO_DIR/mcp/requirements.txt"

info "Installing delegate server to /opt/hermes-pi/mcp..."
sudo mkdir -p /opt/hermes-pi/mcp
sudo cp "$REPO_DIR/mcp/claude_delegate_server.py" /opt/hermes-pi/mcp/

info "Installing systemd service..."
sudo sed \
  -e "s|{{DELEGATE_PORT}}|$CLAUDE_DELEGATE_PORT|g" \
  -e "s|{{WORKSPACE_DIR}}|$WORKSPACE_DIR|g" \
  -e "s|{{HERMES_USER}}|$USER|g" \
  -e "s|{{HERMES_HOME_DIR}}|$HOME|g" \
  "$REPO_DIR/mcp/claude-delegate.service" | sudo tee /etc/systemd/system/hermes-claude-delegate.service > /dev/null

sudo systemctl daemon-reload
sudo systemctl enable hermes-claude-delegate.service
sudo systemctl restart hermes-claude-delegate.service

sleep 2
if systemctl is-active --quiet hermes-claude-delegate.service; then
  info "✓ Claude Code delegate service started on port $CLAUDE_DELEGATE_PORT."
else
  warn "Delegate service may not have started. Check: journalctl -u hermes-claude-delegate -f"
fi

info ""
info "═══════════════════════════════════════════════════"
info "  gh + Claude Code CLI installed. One-time setup, then Hermes handles the rest:"
info ""
info "  1) GitHub CLI — authenticate as yourself:"
info "       gh auth login"
info "     Pick: GitHub.com → HTTPS → Login with a web browser."
info "     It prints a one-time code and a URL — open the URL on your laptop,"
info "     paste the code there, and approve. Verify with:"
info "       gh auth status"
info ""
info "  2) Claude Code CLI — log in with your Claude Pro/Max subscription:"
info "       claude"
info "     On first run it prints a login URL. Open it on your laptop (not the"
info "     Pi — there's no browser here). If the browser can't redirect back to"
info "     the Pi, it shows a short code instead — paste that code back into"
info "     this SSH session when prompted. Verify with:"
info "       claude doctor"
info "     Then run: sudo systemctl restart hermes-claude-delegate"
info "     (picks up the new credentials for the already-running delegate service)"
info ""
info "  That's it — no more SSH needed after this. From any Telegram chat, just"
info "  ask Hermes to delegate coding work, e.g.:"
info "    \"delegate to Claude Code: fix the flaky test in PapaDanielVi/some-repo\""
info "  Hermes calls the local delegate service (hermes-claude-delegate.service,"
info "  port $CLAUDE_DELEGATE_PORT), which runs Claude Code unattended with full"
info "  tool access (--dangerously-skip-permissions, your explicit choice) inside"
info "  $WORKSPACE_DIR."
info "═══════════════════════════════════════════════════"
