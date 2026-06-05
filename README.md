# hermes-pi

Self-hosted Hermes Agent on Raspberry Pi 5 with:

- Telegram gateway (two-user allowlist)
- Per-user memory backed up to a private GitHub repo
- Local Chromium browser for web search (no third-party APIs)

**Target hardware:** Raspberry Pi 5 · 8 GB RAM · 256 GB SD card · Pi OS Bookworm 64-bit

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
│   └── skill-browser.md         ← copied to ~/.hermes/skills/
├── browser/
│   ├── browser_server.py        ← FastAPI + Playwright search/fetch server
│   ├── requirements.txt
│   └── browser.service          ← systemd unit file
└── memory/
    ├── sync.sh                  ← git push per-user memory snapshots
    ├── export_sessions.py       ← dumps state.db per Telegram user
    └── cron_setup.sh            ← installs the cron job
```

---

## Step-by-step setup

### 1  Flash and prepare Pi OS

Use **Raspberry Pi OS Lite 64-bit (Bookworm)**. Enable SSH during flash.
No desktop environment needed.

```bash
# After first SSH login, expand filesystem and update
sudo raspi-config --expand-rootfs
sudo apt update && sudo apt full-upgrade -y
sudo reboot
```

### 2  Clone this repo onto the Pi

```bash
cd ~
git clone https://github.com/YOUR_USERNAME/hermes-pi.git
cd hermes-pi
cp .env.example .env
nano .env          # fill in all required values (see .env.example comments)
```

### 3  Run the installer

```bash
chmod +x install.sh
./install.sh
```

The installer runs five sub-scripts in order:
- `scripts/01_system_deps.sh`  — Docker, Python 3.11, Chromium, Xvfb, git
- `scripts/02_hermes_init.sh`  — creates `~/.hermes`, applies config template
- `scripts/03_browser_setup.sh`— installs Playwright, playwright-stealth, starts service
- `scripts/04_hermes_start.sh` — pulls Docker image and starts Hermes
- `scripts/05_github_memory.sh`— configures git credentials and installs cron job

### 4  Allowlist your two Telegram users

Get each user's numeric Telegram ID by having them message `@userinfobot`.
Put both IDs in `.env`:

```
TELEGRAM_ALLOWED_USERS=111111111,222222222
```

Then restart Hermes:
```bash
docker compose restart hermes
```

### 5  Test

Have each user send `/start` to the bot. They should receive a greeting.
Ask the agent to "search for today's news about Raspberry Pi" to verify
the browser tool is working.

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

Sync runs every 30 minutes via cron and on `docker stop`.

---

## Updating Hermes

```bash
docker compose pull
docker compose up -d
```

---

## Logs

```bash
docker compose logs -f hermes          # Hermes gateway
journalctl -u hermes-browser -f        # Browser server
crontab -l                             # See memory sync schedule
```
