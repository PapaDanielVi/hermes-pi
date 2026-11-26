# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

hermes-pi is a self-hosted Hermes Agent deployment for Raspberry Pi 5 that provides:
- Telegram gateway with two-user allowlist
- Memory and skills, optionally backed up to a private GitHub repo (skip it to keep everything local, no off-device copy)
- Local Chromium browser for web search (no third-party APIs)
- Voice mode: Telegram voice notes transcribed by local Whisper (STT) and spoken replies via Edge TTS
- Optional coding delegation: Hermes can hand off real coding tasks to the Claude Code CLI via a local MCP tool

## Architecture

```
Telegram ──► Hermes Gateway (Docker) ──► LLM (Anthropic / OpenRouter / Google Antigravity)
                │                           │
                ├── ~/.hermes/state.db       ├── Browser Server (localhost:5555)
                │   (SQLite, per-session)    │   Playwright + Chromium + Xvfb
                │                            │
                ├── GitHub Sync (cron)       ├── DuckDuckGo / direct fetch
                │   per-user memory folders  │
                │                            └── Claude Delegate (localhost:5556)
                └── MCP: Claude Code delegate     MCP server → `claude -p` → gh-cloned
                    (optional, off by default)     repo under ~/coding-workspace
```

Three processes can run concurrently (the third is optional):
1. **Hermes** in Docker via `docker-compose up -d` (`network_mode: host`, so it
   reaches everything below at `localhost:<port>` with no extra networking)
2. **Browser server** as a systemd service (`browser_server.py` on port 5555)
3. **Claude Code delegate** as a systemd service (`hermes-claude-delegate.service`,
   `claude_delegate_server.py` on port 5556) — optional, only when
   `HERMES_INSTALL_DEV_TOOLS=1`

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

# View Claude Code delegate logs (only when HERMES_INSTALL_DEV_TOOLS=1)
journalctl -u hermes-claude-delegate -f

# Restart Hermes after config changes
docker compose restart hermes

# Update Hermes to latest image
docker compose pull && docker compose up -d
```

## Installation Flow

`install.sh` is an interactive entrypoint with two modes:

- **local** — installs on the current machine (the Pi). Runs `00_configure.sh`
  (prompts, writes `.env`), `00_preflight.sh` (requires 64-bit + apt, sets
  `HERMES_MEM_LIMIT`), then the seven sub-scripts below.
- **remote** — collects config on the controlling machine, then copies the repo and
  `.env` to the Pi over SSH and runs `install.sh --local --noninteractive` there.

Flags: `--local`, `--remote`, `--noninteractive`. The Telegram channel and LLM
provider are skippable in `00_configure.sh`; the post-install summary tells the user
how to configure them later via `docker exec -it hermes hermes config`.

Sub-scripts (local mode), in order:

1. `scripts/01_system_deps.sh` — Docker, Python, uv, Chromium, Xvfb, git
2. `scripts/02_hermes_init.sh` — creates `~/.hermes`, writes `config.yaml` (telegram
   block only when a token is set; voice/STT/TTS block appended when enabled)
3. `scripts/03_browser_setup.sh` — installs Python deps with uv, Playwright browsers,
   starts service (browser port templated from `.env`)
4. `scripts/04_hermes_start.sh` — pulls Docker image and starts Hermes
5. `scripts/05_github_memory.sh` — configures git, installs the sync cron, and
   enables + starts `hermes.service` (boot auto-start, memory sync on shutdown)
6. `scripts/06_security_check.sh` — read-only security review of the Pi; prints
   findings and suggested fixes, changes nothing
7. `scripts/07_dev_tools.sh` — optional, off by default: installs GitHub CLI + Claude
   Code CLI on the Pi host itself (never inside the Hermes container), authenticated
   as the user's own GitHub account and Claude Pro/Max subscription, then installs
   and starts `hermes-claude-delegate.service` (the MCP server in `mcp/`) so Hermes
   can call `delegate_coding_task` directly from Telegram. Since everything lands on
   the host filesystem, updating Hermes (`docker compose pull && docker compose up -d`)
   never touches or removes it. A one-time `gh auth login` + `claude` login over SSH
   is still required after install (OAuth needs a real browser once); day-to-day use
   is Telegram-only.

`00_configure.sh` has five interactive steps: Telegram channel, GitHub memory repo,
LLM provider, voice mode (STT/TTS provider selection), and dev tools (coding
delegation via gh + Claude Code CLI, off by default). Voice is enabled by default
with local Whisper + Edge TTS (no keys required).

All scripts source `scripts/lib/common.sh` for logging and prompt helpers.

## Environment Variables (.env)

Normally generated by `00_configure.sh`. Everything below is optional / skippable
(can be set later inside the container, or by re-running `./install.sh`):
- `TELEGRAM_BOT_TOKEN` — Bot token from @BotFather
- `TELEGRAM_ALLOWED_USERS` — Comma-separated Telegram user IDs
- `ANTHROPIC_API_KEY` — For Anthropic LLM
- `OPENROUTER_API_KEY` — For OpenRouter LLM
- `HERMES_ANTIGRAVITY_ENABLED` - Set to `1` to use Google Antigravity OAuth via [neerazz/hermes-antigravity-oauth](https://github.com/neerazz/hermes-antigravity-oauth) (no API key). Installs `agy` into `~/.hermes/.local/bin/agy` and installs/enables the plugin in `scripts/04_hermes_start.sh`; sets `model.provider: antigravity-oauth` and `plugins.enabled: [antigravity-oauth]` in `scripts/02_hermes_init.sh`.
- `ANTIGRAVITY_MODEL` - Optional exact model ID from `agy models` (leave empty to let `agy` use its default, or set later with `hermes config set model.default`).
- `ANTIGRAVITY_WORKSPACE_RULES` - Default `1` (`0` sends SOUL/system instructions inline instead of `GEMINI.md`).
- `ANTIGRAVITY_CONTEXT_LENGTH` - Optional positive integer context length override.
- `GITHUB_TOKEN` — Personal access token for the memory repo. Leave unset (along
  with `GITHUB_MEMORY_REPO`) to keep memory and skills local to the Pi only, with
  no GitHub backup, no memory-sync cron job, and no off-device copy.
- `GITHUB_MEMORY_REPO` — Repository as `https://github.com/owner/repo`. Must be
  set together with `GITHUB_TOKEN` — one without the other is a config error, not
  "disabled".

Tuning (set automatically):
- `HERMES_MEM_LIMIT` — Container memory cap, chosen by `00_preflight.sh` per board
- `BROWSER_SERVER_PORT` — Default 5555
- `HERMES_DASHBOARD` — Default 1 (enable dashboard)

Voice mode (set by `00_configure.sh` Step 4; voice is on by default):
- `HERMES_VOICE_ENABLED` — 1 to enable, 0 to disable
- `HERMES_STT_PROVIDER` — `local` (default), `groq`, or `openai`
- `HERMES_STT_MODEL` — Whisper model size; default `base`, use `tiny` on low-RAM boards
- `HERMES_TTS_PROVIDER` — `edge` (default), `elevenlabs`, `openai`, or `piper`
- `HERMES_TTS_VOICE` — Edge voice name; default `en-US-AriaNeural`
- `GROQ_API_KEY` — Only needed when `HERMES_STT_PROVIDER=groq`
- `ELEVENLABS_API_KEY` — Only needed when `HERMES_TTS_PROVIDER=elevenlabs`
- `VOICE_TOOLS_OPENAI_KEY` — Only needed when STT or TTS provider is `openai`

Dev tools / coding delegation (set by `00_configure.sh` Step 5; off by default):
- `HERMES_INSTALL_DEV_TOOLS` — 1 to install GitHub CLI + Claude Code CLI + the
  delegate MCP server on the Pi host via `scripts/07_dev_tools.sh`, 0 (default) to
  skip. Unrelated to the Hermes container's own `GITHUB_TOKEN`/`ANTHROPIC_API_KEY`
  — this uses the user's own GitHub account and Claude subscription so Hermes can
  delegate coding tasks to Claude Code from Telegram.
- `CLAUDE_DELEGATE_PORT` — Loopback port for `hermes-claude-delegate.service`;
  default 5556. Written into `~/.hermes/config.yaml` as an `mcp_servers.claude_code`
  entry by `02_hermes_init.sh` when `HERMES_INSTALL_DEV_TOOLS=1`.

Voice STT/TTS run inside the `nousresearch/hermes-agent` container (no sidecar
service). The container image already includes ffmpeg and faster-whisper. The Whisper
model (~150 MB for `base`) downloads automatically on the first voice note and is
cached in `~/.hermes/cache/huggingface` via `HF_HOME` in `docker-compose.yml`.

## GitHub Memory Layout

GitHub backup is optional (see Environment Variables above). When enabled, the
sync pushes to a private repo organized as:

```
memory-repo/
├── shared/
│   ├── MEMORY.md      ← Copy of ~/.hermes/memories/MEMORY.md (agent's global memory)
│   ├── USER.md        ← Copy of ~/.hermes/memories/USER.md (agent's notes on the user)
│   ├── skills.md      ← Auto-written index of skill filenames
│   └── skills/        ← Mirror of ~/.hermes/skills/ (the actual skill files)
└── users/
    └── <telegram_id>/
        ├── profile.md   ← Generated by memory/export_sessions.py
        └── sessions.md  ← Last-30-sessions summary, exported from state.db
```

`memory/sync.sh` (idempotent — never re-clones or wipes `~/.hermes/memory-sync` once
it exists) is the single source of truth for the clone; `scripts/05_github_memory.sh`
runs it once during install instead of duplicating the clone/seed logic. Sync runs
every 30 minutes via cron and on graceful container stop (`scripts/hermes-stop.sh`,
which treats a sync failure as non-fatal so the container always stops).

Hermes itself has no per-Telegram-user isolation by default: `MEMORY.md`/`USER.md`
under `~/.hermes/memories/` and skills under `~/.hermes/skills/` are shared across
every allowed user unless separate Hermes profiles are configured per user. The
`users/<telegram_id>/` split above only applies to the exported session history,
not to skills or curated memory.

## Implementation Files

These files are part of the implementation:

### Config
- `config/config.yaml.template` - Body of the Hermes config: native `web` (keyless fallback/rescue + cache), `browser` (`browser_exec` headless Chromium tuning for Pi), `agent` tool-use guards (`intent_ack_continuation`, `stall_guards`, `parallel_tool_call_guidance`), `model`, `kanban`, `memory` (telegram block prepended by `02` when a token is set; `plugins.enabled` and `mcp_servers.claude_code` at `http://127.0.0.1:<port>/mcp` appended when enabled)
- `config/voice.yaml.template` - Voice/STT/TTS config fragment (STT_PROVIDER, STT_MODEL, TTS_PROVIDER, TTS_VOICE substituted; appended by `02` when `HERMES_VOICE_ENABLED=1`)
- `config/skill-browser.md` - Installed to `~/.hermes/skills/local-browser/SKILL.md` with YAML frontmatter; guides Hermes to prefer native `web_search`/`web_extract`/`browser_exec` and fall back to the local Playwright stealth server on `127.0.0.1:<BROWSER_SERVER_PORT>`
- `config/hermes.service` - systemd unit for the Hermes container (boot start, memory sync on stop)

### Browser Server
- `browser/browser_server.py` - Async FastAPI + `async_playwright` loopback fallback server (`/search`, `/fetch`, `/health`) bound to `127.0.0.1`, with lazy Chromium launch, idle shutdown reaper, v1/v2 `playwright-stealth` support, URL encoding, and DuckDuckGo redirect unwrapping
- `browser/requirements.txt` - Python dependencies (fastapi, uvicorn, playwright, playwright-stealth)
- `browser/browser.service` - systemd unit running `/opt/hermes-pi/browser/browser_server.py` on `127.0.0.1`

### Memory Sync
- `memory/sync.sh` — Main sync script that exports sessions and pushes to GitHub
- `memory/export_sessions.py` — Exports SQLite state.db to per-user markdown files
- `memory/cron_setup.sh` — Installs 30-minute cron job for sync

### Claude Code Delegate (optional)
- `mcp/claude_delegate_server.py` — MCP server (FastMCP, streamable-http transport)
  exposing one tool, `delegate_coding_task(repo, task)`: clones/pulls `repo` via
  `gh` into `~/coding-workspace`, then runs
  `claude --dangerously-skip-permissions -p "<task>" --output-format json`
  in it and returns the result (no `--bare`: that mode skips OAuth/keychain reads
  and would force API-key billing instead of the user's Claude subscription)
- `mcp/requirements.txt` — Python dependency (`mcp`)
- `mcp/claude-delegate.service` — systemd unit template for `hermes-claude-delegate.service`;
  runs as the install-time user (needed for `~/.claude`/`~/.config/gh` credential
  access) with `ProtectSystem=strict`/`ProtectHome=read-only` and `ReadWritePaths`
  scoped to the workspace + credential paths

### Installation Scripts
- `install.sh` — Interactive entrypoint (local/remote modes, arg parsing, SSH push)
- `scripts/lib/common.sh` — Sourced logging + prompt helpers and `.env` get/set
- `scripts/00_preflight.sh` — Requires 64-bit + apt; sets `HERMES_MEM_LIMIT` per board
- `scripts/00_configure.sh` — Interactive `.env` generation (skippable channel/provider)
- `scripts/01_system_deps.sh` — Installs Docker, uv, Python, Chromium, Xvfb, git
- `scripts/02_hermes_init.sh` — Creates ~/.hermes and applies config template
- `scripts/03_browser_setup.sh` — Uses uv to install Python deps, Playwright chromium, starts service
- `scripts/04_hermes_start.sh` — Pulls and starts Hermes Docker container
- `scripts/05_github_memory.sh` — Configures git and installs cron job
- `scripts/06_security_check.sh` — Read-only post-install security review; suggests fixes, makes no changes
- `scripts/07_dev_tools.sh` — Optional, off by default: installs GitHub CLI + Claude Code CLI + the delegate MCP service on the Pi host (not the container)
- `scripts/hermes-stop.sh` — Stops Hermes with memory sync (for graceful shutdown)