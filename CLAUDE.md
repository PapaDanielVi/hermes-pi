# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

hermes-pi is a self-hosted Hermes Agent deployment for Raspberry Pi 5 that provides:
- Telegram gateway with two-user allowlist
- Per-user memory backed up to a private GitHub repo
- Local Chromium browser for web search (no third-party APIs)

## Architecture

```
Telegram ──► Hermes Gateway (Docker) ──► LLM API (Anthropic / OpenRouter)
                │                           │
                ├── ~/.hermes/state.db       ├── Browser Server (localhost:5555)
                │   (SQLite, per-session)      │   Playwright + Chromium + Xvfb
                │                             │
                └── GitHub Sync (cron)       └── DuckDuckGo / direct fetch
                    per-user memory folders
```

Two processes run concurrently:
1. **Hermes** in Docker via `docker-compose up -d`
2. **Browser server** as a systemd service (`browser_server.py` on port 5555)

## Development Commands

### Local Development (on development machine)

```bash
# Validate bash scripts syntax
bash -n install.sh
bash -n scripts/*.sh

# View .env structure
cat .env.example
```

### On Raspberry Pi (after deployment)

```bash
# Start Hermes gateway
docker compose up -d

# View Hermes logs
docker compose logs -f hermes

# View browser server logs
journalctl -u hermes-browser -f

# Test browser server health
curl http://localhost:5555/health

# Restart Hermes after config changes
docker compose restart hermes

# Update Hermes to latest image
docker compose pull && docker compose up -d
```

## Installation Flow

The `install.sh` script orchestrates five sub-scripts in order:

1. `scripts/01_system_deps.sh` — Docker, Python, uv, Chromium, Xvfb, git
2. `scripts/02_hermes_init.sh` — creates `~/.hermes`, applies config template
3. `scripts/03_browser_setup.sh` — installs Python deps with uv, Playwright browsers, starts service
4. `scripts/04_hermes_start.sh` — pulls Docker image and starts Hermes
5. `scripts/05_github_memory.sh` — configures git credentials and installs cron job

## Environment Variables (.env)

Required variables:
- `TELEGRAM_BOT_TOKEN` — Bot token from @BotFather
- `TELEGRAM_ALLOWED_USERS` — Comma-separated Telegram user IDs
- `GITHUB_TOKEN` — Personal access token for memory repo
- `GITHUB_MEMORY_REPO` — Repository in `owner/repo` format

Optional:
- `BROWSER_SERVER_PORT` — Default 5555
- `HERMES_DASHBOARD` — Default 1 (enable dashboard)
- `ANTHROPIC_API_KEY` — For Anthropic LLM
- `OPENROUTER_API_KEY` — For OpenRouter LLM

## GitHub Memory Layout

The sync pushes to a private repo organized as:

```
memory-repo/
├── shared/
│   ├── MEMORY.md      ← Agent's global learned memory
│   └── skills.md      ← Auto-written skills list
└── users/
    └── <telegram_id>/
        ├── profile.md   ← USER.md for this Telegram user
        └── sessions.md  ← Last-30-days session summaries
```

Sync runs every 30 minutes via cron and on graceful container stop.

## Implementation Files

These files are part of the implementation:

### Config
- `config/config.yaml.template` — Template for Hermes config (TELEGRAM_BOT_TOKEN, BROWSER_SERVER_PORT substituted)
- `config/skill-browser.md` — Skill teaching Hermes the browser API endpoints

### Browser Server
- `browser/browser_server.py` — FastAPI server with Playwright endpoints (`/search`, `/fetch`, `/health`)
- `browser/requirements.txt` — Python dependencies (fastapi, uvicorn, playwright, playwright-stealth)
- `browser/browser.service` — systemd unit for the browser service

### Memory Sync
- `memory/sync.sh` — Main sync script that exports sessions and pushes to GitHub
- `memory/export_sessions.py` — Exports SQLite state.db to per-user markdown files
- `memory/cron_setup.sh` — Installs 30-minute cron job for sync

### Installation Scripts
- `scripts/01_system_deps.sh` — Installs Docker, uv, Python, Chromium, Xvfb, git
- `scripts/02_hermes_init.sh` — Creates ~/.hermes and applies config template
- `scripts/03_browser_setup.sh` — Uses uv to install Python deps, Playwright chromium, starts service
- `scripts/04_hermes_start.sh` — Pulls and starts Hermes Docker container
- `scripts/05_github_memory.sh` — Configures git and installs cron job
- `scripts/hermes-stop.sh` — Stops Hermes with memory sync (for graceful shutdown)