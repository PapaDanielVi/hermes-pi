# hermes-pi

Self-hosted Hermes Agent on Raspberry Pi 5 with:

- Telegram gateway (two-user allowlist)
- Per-user memory backed up to a private GitHub repo
- Local Chromium browser for web search (no third-party APIs)
- Voice mode: send voice notes, get spoken replies as Telegram voice bubbles

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
Telegram ──► Hermes Gateway (Docker) ──► LLM (Anthropic / OpenRouter / Google Antigravity)
  (text +          │                           │
  voice notes)     ├── ~/.hermes/state.db       ├── Browser Server (localhost:5555)
                   │   (SQLite, per-session)    │   Playwright + Chromium + Xvfb
                   │                           │
                   ├── Voice: STT (Whisper)    └── DuckDuckGo / direct fetch
                   │   + TTS (Edge) inside
                   │   the container
                   │
                   └── GitHub Sync (cron)
                       per-user memory folders
```

Two separate processes run alongside each other (plus an optional third for Claude Code delegation):
1. **Hermes** in Docker (`docker-compose up -d`) with built-in keyless `web_search`/`web_extract`, built-in headless Chromium (`browser_exec` over CDP), `terminal`, file tools, memory, skills, cron, and kanban
2. **Local Playwright browser fallback** as a systemd service (`browser_server.py` on `127.0.0.1:5555`), launched lazily on demand and reaped when idle

Hermes uses its native `web_search`, `web_extract`, and `browser_exec` tools first. The `~/.hermes/skills/local-browser/SKILL.md` skill also teaches Hermes to fall back to the local Playwright + stealth server on `127.0.0.1:5555` via `terminal` if keyless search hits rate limits or a site blocks standard requests.

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
│   ├── voice.yaml.template      ← voice/STT/TTS config (appended when enabled)
│   ├── skill-browser.md         ← copied to ~/.hermes/skills/
│   └── hermes.service           ← systemd unit (optional, for auto start/stop)
├── browser/
│   ├── browser_server.py        ← FastAPI + Playwright search/fetch server
│   ├── requirements.txt
│   └── browser.service          ← systemd unit file template
├── memory/
│   ├── sync.sh                  ← git push per-user memory snapshots
│   ├── export_sessions.py       ← dumps state.db per Telegram user
│   └── cron_setup.sh            ← installs the cron job
└── mcp/
    ├── claude_delegate_server.py ← MCP server wrapping the Claude Code CLI
    ├── requirements.txt
    └── claude-delegate.service   ← systemd unit file template
scripts/
├── 01_system_deps.sh            ← System packages install
├── 02_hermes_init.sh            ← Hermes home init
├── 03_browser_setup.sh          ← Browser service setup
├── 04_hermes_start.sh           ← Docker start
├── 05_github_memory.sh          ← GitHub sync config
├── 06_security_check.sh         ← Read-only security review (suggestions only)
├── 07_dev_tools.sh              ← Optional: gh + Claude Code CLI + delegate service
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
- `scripts/07_dev_tools.sh` — optional, off by default: installs GitHub CLI + Claude
  Code CLI and the Claude Code delegate MCP service on the Pi host (never inside
  the Hermes container)

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

## Google Antigravity OAuth provider

You can run Hermes on a Google Antigravity plan with no API key by picking `antigravity` in Step 3/5 of `./install.sh` (or setting `HERMES_ANTIGRAVITY_ENABLED=1` in `.env`).

The installer sets up two things inside `~/.hermes` (mounted at `/opt/data` in the container, so both survive `docker compose pull && docker compose up -d`):

1. Google's official Antigravity CLI (`agy`) at `~/.hermes/.local/bin/agy`, which is already on `PATH` inside the Hermes image.
2. The [neerazz/hermes-antigravity-oauth](https://github.com/neerazz/hermes-antigravity-oauth) plugin, enabled in `~/.hermes/config.yaml` with `model.provider: antigravity-oauth`.

After install, complete the one-time Google sign-in over SSH and choose an exact model ID from your plan:

```bash
# 1. Sign in (prints a Google URL to open on your laptop; paste the code back within ~60s)
docker exec -it hermes hermes auth add antigravity-oauth

# 2. List exact model IDs available on your plan
docker exec -it -u hermes -e HOME=/opt/data hermes agy models

# 3. Set your default model and restart Hermes
docker exec -it hermes hermes config set model.default '<exact-model-id>'
docker compose restart hermes
```

Check session health or model-group quota any time:

```bash
docker exec -it hermes hermes auth status antigravity-oauth
docker exec -it hermes hermes usage --provider antigravity-oauth
```

The agy OAuth session is stored under `~/.hermes/.gemini/antigravity-cli/` and is excluded from GitHub memory sync and `~/.hermes/.gitignore`. Optional tuning variables (`ANTIGRAVITY_MODEL`, `ANTIGRAVITY_WORKSPACE_RULES`, `ANTIGRAVITY_CONTEXT_LENGTH`) are documented in `.env.example`.

---

## Voice mode

The installer enables voice mode by default. No API keys or extra packages are
needed: transcription runs via [faster-whisper](https://github.com/SYSTRAN/faster-whisper)
inside the Hermes container (the `base` Whisper model, ~150 MB, downloads on the first
voice note), and replies are synthesised by Microsoft Edge TTS (free, cloud-based)
then converted to OGG/Opus by ffmpeg — both already in the official image.

Voice replies are off by default so text conversations are unaffected. Toggle per
chat at runtime:

| Command | Effect |
|---------|--------|
| `/voice on` | Voice reply only when you send a voice note |
| `/voice tts` | Voice reply for every message |
| `/voice off` | Back to text-only |
| `/voice status` | Show the current mode |

**Sending a voice note:** record a voice message in Telegram as normal. The bot
transcribes it, replies in text (and in audio when voice is on).

**RAM note:** the `base` Whisper model peaks at ~1 GB during transcription. On a 2 GB
Pi 4 set `HERMES_STT_MODEL=tiny` in `.env` and re-run `./install.sh` to regenerate
`~/.hermes/config.yaml`.

**Cloud providers:** if you prefer faster or higher-quality transcription/TTS, the
installer's Step 4 lets you pick Groq (STT) or ElevenLabs/OpenAI (TTS) instead.

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

## Delegating coding tasks to Claude Code

Optional and off by default. Enable it during install (Step 5/5 in the configure
prompts) or later by re-running `./install.sh` and answering yes. This gives
**Hermes itself** a tool for delegating real coding work to the Claude Code CLI,
so you can ask for it right from Telegram instead of doing it yourself:

```
you (Telegram): delegate to Claude Code: fix the flaky test in PapaDanielVi/some-repo
```

Under the hood, enabling this installs three things **on the Pi host** (never
inside the Hermes container):

1. `gh` and the Claude Code CLI, authenticated as **you** — your own GitHub
   account and Claude Pro/Max subscription, completely separate from the
   `GITHUB_TOKEN`/`ANTHROPIC_API_KEY` the Hermes container uses for memory
   backup and chat replies.
2. `hermes-claude-delegate.service` — a small local MCP server
   (`mcp/claude_delegate_server.py`) that Hermes calls over `localhost` (the
   container runs with `network_mode: host`, so no networking setup is needed).
   It clones/pulls the repo you name via `gh`, then runs
   `claude --dangerously-skip-permissions -p "<task>"` against it and returns
   the result.
3. `~/coding-workspace` — where repos get cloned to.

Because all of this lives on the host filesystem (not the Hermes Docker image),
running `docker compose pull && docker compose up -d` to update Hermes never
touches or removes it.

**One-time setup after install** (this part still needs SSH — Claude Code's
login is an OAuth flow that needs a real browser once; day-to-day use afterwards
is Telegram-only):

```bash
ssh <user>@<pi-host>

# 1. GitHub CLI — authenticate as yourself
gh auth login
# Choose: GitHub.com → HTTPS → Login with a web browser.
# Copy the one-time code shown, open the printed URL on your laptop, paste
# the code, approve. Confirm it worked:
gh auth status

# 2. Claude Code CLI — log in with your Claude subscription (not an API key)
claude
# First run prints a login URL. Open it on your laptop's browser (the Pi has
# no display). If the browser can't reach back to the Pi it shows a short
# code instead — paste that into this SSH session. Confirm it worked:
claude doctor

# 3. Restart the delegate service so it picks up the credentials
sudo systemctl restart hermes-claude-delegate
```

From then on, no more SSH: ask Hermes in Telegram to delegate a coding task, and
it calls the local service for you.

**Security note:** Claude Code runs unattended with `--dangerously-skip-permissions`
— every allowed Telegram user can trigger real file edits, shell commands, and
`git`/`gh` operations under your identity, with no per-action confirmation. The
`hermes-claude-delegate.service` systemd unit sandboxes the process at the OS
level (`ProtectSystem=strict`, `ProtectHome=read-only`, with write access only to
`~/coding-workspace` and the `gh`/`claude` credential paths), but Claude Code
itself is not further restricted within that boundary. Only enable this if you
trust everyone in `TELEGRAM_ALLOWED_USERS` with that level of access.

Check the service any time:

```bash
systemctl status hermes-claude-delegate
journalctl -u hermes-claude-delegate -f
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
