#!/usr/bin/env bash
# scripts/06_security_check.sh
# Read-only security review of the Pi, run at the end of the install. It reports
# common hardening gaps and prints the command to fix each one. It makes NO
# changes to the system: every finding is a suggestion for you to apply if you want.
#
# -e is intentionally OFF here: a probe that fails (missing tool, no permission)
# should never abort the review or fail the install.
set -uo pipefail

REPO_DIR="${REPO_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
LOG_TAG="06_security_check"
# shellcheck source=scripts/lib/common.sh
source "$REPO_DIR/scripts/lib/common.sh"

ENV_FILE="$REPO_DIR/.env"

# Findings accumulate here. Each entry is a short title followed by an indented
# "Fix:" line so the report is copy-paste friendly.
FINDINGS=()
add_finding() { FINDINGS+=("$1"); }

info "Running a quick security review (read-only, nothing will be changed)…"

# ── 1. .env file permissions ──────────────────────────────────
# .env holds the GitHub token and any LLM/Telegram secrets. It should not be
# readable by other local users.
if [[ -f "$ENV_FILE" ]]; then
  perms="$(stat -c '%a' "$ENV_FILE" 2>/dev/null || echo "")"
  if [[ -n "$perms" && "$perms" != "600" && "$perms" != "400" ]]; then
    add_finding ".env is mode $perms — other local users can read your GitHub token and API keys.
      Fix:  chmod 600 \"$ENV_FILE\""
  fi
fi

# ── 2. Default 'pi' account ───────────────────────────────────
# 'pi' is the best-known username on these boards and the first thing brute-force
# scanners try.
if id pi &>/dev/null; then
  add_finding "The default 'pi' user exists, a common brute-force target.
      Fix:  create your own user, then disable login for 'pi':
            sudo adduser <youruser> && sudo usermod -aG sudo <youruser>
            sudo passwd -l pi"
fi

# ── 3. SSH configuration ──────────────────────────────────────
# Read the effective values from sshd_config and any drop-ins (best effort, no
# sudo so we never block on a prompt). Files are world-readable on a default OS.
ssh_setting() {
  local key="$1"
  grep -rhiE "^[[:space:]]*${key}[[:space:]]+" \
      /etc/ssh/sshd_config /etc/ssh/sshd_config.d/*.conf 2>/dev/null \
    | tail -n1 | awk '{print tolower($2)}'
}

if [[ -r /etc/ssh/sshd_config ]] || ls /etc/ssh/sshd_config.d/*.conf &>/dev/null; then
  pw_auth="$(ssh_setting PasswordAuthentication)"
  # Default when unset is "yes", so treat anything other than an explicit "no" as on.
  if [[ "$pw_auth" != "no" ]]; then
    add_finding "SSH password authentication is enabled. Key-based auth resists brute force far better.
      Fix:  add your key with ssh-copy-id, then set in /etc/ssh/sshd_config:
            PasswordAuthentication no
            sudo systemctl restart ssh"
  fi

  root_login="$(ssh_setting PermitRootLogin)"
  if [[ "$root_login" == "yes" ]]; then
    add_finding "SSH permits direct root login (PermitRootLogin yes).
      Fix:  in /etc/ssh/sshd_config set 'PermitRootLogin no', then:
            sudo systemctl restart ssh"
  fi
fi

# ── 4. SSH brute-force protection ─────────────────────────────
if ! command -v fail2ban-client &>/dev/null; then
  add_finding "No fail2ban detected. It bans IPs after repeated failed SSH logins.
      Fix:  sudo apt install -y fail2ban"
fi

# ── 5. Host firewall ──────────────────────────────────────────
# Hermes needs no inbound ports, so a firewall is defense in depth: it limits
# exposure to SSH only and blocks anything else listening by accident.
if systemctl is-active --quiet ufw 2>/dev/null \
   || systemctl is-active --quiet nftables 2>/dev/null \
   || systemctl is-active --quiet firewalld 2>/dev/null; then
  : # a firewall is active.
else
  add_finding "No active host firewall detected. Hermes needs no inbound ports, so you can lock it down.
      Fix:  sudo apt install -y ufw && sudo ufw allow OpenSSH && sudo ufw enable"
fi

# ── 6. Automatic security updates ─────────────────────────────
if ! dpkg-query -W -f='${Status}' unattended-upgrades 2>/dev/null | grep -q "install ok installed"; then
  add_finding "Automatic security updates are not installed; patches won't apply on their own.
      Fix:  sudo apt install -y unattended-upgrades && sudo dpkg-reconfigure -plow unattended-upgrades"
fi

# ── 7. Pending package updates ────────────────────────────────
# apt-get -s is a simulation and needs no root.
pending="$(apt-get -s upgrade 2>/dev/null | grep -c '^Inst' || true)"
if [[ "${pending:-0}" -gt 0 ]]; then
  add_finding "$pending package update(s) are pending, some may be security fixes.
      Fix:  sudo apt update && sudo apt full-upgrade -y"
fi

# ── Report ────────────────────────────────────────────────────
echo
if (( ${#FINDINGS[@]} == 0 )); then
  info "✓ Security review: no common issues found."
else
  warn "Security review found ${#FINDINGS[@]} thing(s) worth a look:"
  i=1
  for f in "${FINDINGS[@]}"; do
    echo
    warn "  $i) $f"
    ((i++))
  done
  echo
  note "These are suggestions only — nothing was changed on your system."
  note "Apply the fixes you're comfortable with; none are required for Hermes to run."
fi

# ── Persist findings so the post-install summary can surface them ─
# Both files land in logs/ which is already gitignored.
HERMES_LOGS="$HOME/.hermes/logs"
mkdir -p "$HERMES_LOGS"

REVIEW_FILE="$HERMES_LOGS/security-review.txt"
COUNT_FILE="$HERMES_LOGS/.security-findings-count"

{
  echo "# Security review — $(date -Iseconds)"
  echo "# ${#FINDINGS[@]} finding(s)"
  echo
  if (( ${#FINDINGS[@]} == 0 )); then
    echo "✓ No common issues found."
  else
    i=1
    for f in "${FINDINGS[@]}"; do
      echo "$i) $f"
      echo
      ((i++))
    done
    echo "These are suggestions only — nothing was changed on your system."
  fi
} > "$REVIEW_FILE" 2>/dev/null || true

echo "${#FINDINGS[@]}" > "$COUNT_FILE" 2>/dev/null || true

info "✓ Security review complete."
