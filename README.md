# hermes-pi

Self-hosted Hermes Agent on Raspberry Pi 5 with:

- Telegram gateway (two-user allowlist)
- Per-user memory backed up to a private GitHub repo
- Local Chromium browser for web search (no third-party APIs)

**Target hardware:** Raspberry Pi 4 or 5 (2 GB RAM or more) running a 64-bit OS:
Raspberry Pi OS (Bookworm), Ubuntu Server arm64, or Debian arm64. A 32-bit OS will
not work (the Hermes image and Playwright Chromium are 64-bit only). 4 GB or more is
recommended.

The installer prompts for everything it needs and can run in two ways: directly on
the Pi (local), or from your laptop over SSH (remote). It only needs outbound
internet, no inbound ports. Hermes auto-starts on boot and survives power-offs.

---

## Architecture

```
Telegram ──► Hermes Gateway (Docker) ──► LLM API (Anthropic / OpenRouter)
                    │                           │
                    ├── ~/.hermes/state.db       ├── Browser Server (localhost:5555)
                    │   (SQLite, per-session)    │   Playwright + Chromium + Xvfb
                    │                           │
                    └── GitHub Sync (cron)      └── DuckDuckGo / direct fetch
                        per-user memory folders
```

Two separate processes run alongside each other:
1. **Hermes** in Docker (`docker-compose up -d`)
2. **Browser server** as a systemd service (`browser_server.py` on port 5555)

Hermes calls the browser server via its built-in `http_request` tool, guided by a
skill file that teaches it the API contract.

---

## Repository structure

```
hermes-pi/
├── README.md
├── install.sh                   ← run this once on a fresh Pi
├── .env.example                 ← copy to .env and fill in secrets
├── docker-compose.yml
├── config/
│   ├── config.yaml.template     ← copied to ~/.hermes/config.yaml
│   ├── skill-browser.md         ← copied to ~/.hermes/skills/
│   └── hermes.service           ← systemd unit (optional, for auto start/stop)
├── browser/
│   ├── browser_server.py        ← FastAPI + Playwright search/fetch server
│   ├── requirements.txt
│   └── browser.service          ← systemd unit file template
└── memory/
    ├── sync.sh                  ← git push per-user memory snapshots
    ├── export_sessions.py       ← dumps state.db per Telegram user
    └── cron_setup.sh            ← installs the cron job
scripts/
├── 01_system_deps.sh            ← System packages install
├── 02_hermes_init.sh            ← Hermes home init
├── 03_browser_setup.sh          ← Browser service setup
├── 04_hermes_start.sh           ← Docker start
├── 05_github_memory.sh          ← GitHub sync config
├── 06_security_check.sh         ← Read-only security review (suggestions only)
└── hermes-stop.sh               ← Graceful shutdown with sync
```

---

## Step-by-step setup

### 1  Flash a 64-bit OS

Use **Raspberry Pi OS Lite 64-bit (Bookworm)** or Ubuntu Server arm64. Enable SSH
during flash. No desktop environment needed.

```bash
# After first login, expand filesystem and update
sudo raspi-config --expand-rootfs   # Pi OS only
sudo apt update && sudo apt full-upgrade -y
sudo reboot
```

### 2  Get the repo

Clone it wherever you plan to run the installer from (the Pi for local install, or
your laptop for remote install):

```bash
git clone https://github.com/PapaDanielVi/hermes-pi.git
cd hermes-pi
```

### 3  Run the installer

```bash
chmod +x install.sh
./install.sh
```

It first asks where to install:

```
Where is Hermes being installed?
  1) This machine is the Raspberry Pi (local)
  2) A remote Pi over SSH (I'll ask for IP/port/user)
```

Then it prompts for everything it needs and writes `.env` for you. The Telegram
channel and the LLM provider are both **skippable**: press skip and configure them
later from inside the container (see below). The GitHub memory repo is required.

**Remote mode** collects the same config on your laptop, then copies the repo and
`.env` to the Pi over SSH and runs the local installer there. Nothing listens for
inbound connections on the Pi.

Under the hood the local install runs:
- `scripts/00_preflight.sh`   — checks 64-bit + apt, picks a memory limit for the board
- `scripts/00_configure.sh`   — interactive prompts, writes `.env`
- `scripts/01_system_deps.sh` — Docker, Python, uv, Chromium, Xvfb, git
- `scripts/02_hermes_init.sh` — creates `~/.hermes`, writes `config.yaml`
- `scripts/03_browser_setup.sh` — Playwright + Chromium, starts the browser service
- `scripts/04_hermes_start.sh` — pulls the image and starts Hermes
- `scripts/05_github_memory.sh` — configures git, installs the sync cron, enables the
  systemd service for boot/shutdown
- `scripts/06_security_check.sh` — read-only security review of the Pi; prints findings
  and suggested fixes, changes nothing

### 4  Finish configuration (if you skipped any)

If you skipped the Telegram channel or the LLM provider, set them directly inside the
running container, then restart:

```bash
docker exec -it hermes hermes config    # configure provider / channel
docker exec -it hermes bash             # plain shell fallback
docker compose restart hermes
```

You can also just re-run `./install.sh` to add the values to `.env`.

### 5  Test

Have each allowed user send `/start` to the bot. They should receive a greeting.
Ask the agent to "search for today's news about Raspberry Pi" to verify the browser
tool is working.

---

## Security review

The last install step (`scripts/06_security_check.sh`) runs a quick, read-only review
of the Pi and prints anything worth hardening. It never changes the system: every
finding comes with the command to fix it, and you decide what to apply. None of the
fixes are required for Hermes to run.

It checks for:

- `.env` readable by other local users (it holds your GitHub token and API keys)
- the default `pi` account still being present (a common brute-force target)
- SSH password authentication or direct root login being enabled
- no fail2ban (bans IPs after repeated failed SSH logins)
- no active host firewall (Hermes needs no inbound ports, so you can lock it down)
- automatic security updates not installed
- pending package updates

Re-run it any time:

```bash
./scripts/06_security_check.sh
```

---

## GitHub memory layout

The private repo will be organised as:

```
memory-repo/
├── shared/
│   ├── MEMORY.md          ← agent's global learned memory
│   └── skills.md          ← list of auto-written skills
└── users/
    ├── 111111111/
    │   ├── profile.md     ← USER.md for this Telegram user
    │   └── sessions.md    ← last-30-days session summaries
    └── 222222222/
        ├── profile.md
        └── sessions.md
```

Sync runs every 30 minutes via cron. Use `hermes-stop.sh` for graceful shutdown.

```bash
# Graceful shutdown with memory sync (recommended)
./scripts/hermes-stop.sh

# Or manual sync before stop
./memory/sync.sh && docker compose stop hermes
```

---

## Updating Hermes

```bash
docker compose pull
docker compose up -d
```

---

## Reboot and power-off resilience

The installer wires this up automatically, so there is nothing extra to do:

- `hermes-browser.service` and `hermes.service` are both enabled, so Hermes and the
  browser server start on boot.
- The Docker container uses `restart: unless-stopped`, so it self-heals if it crashes.
- On a clean shutdown or reboot, `hermes.service` runs `scripts/hermes-stop.sh`,
  which syncs memory to GitHub before stopping the container.
- The 30-minute sync cron also runs independently, so memory is never more than half
  an hour stale even after an unclean power-off.

Check it after a reboot:

```bash
systemctl is-enabled hermes.service hermes-browser.service
```

## Logs

```bash
docker compose logs -f hermes          # Hermes gateway
journalctl -u hermes-browser -f        # Browser server
crontab -l                             # See memory sync schedule
```
