#!/usr/bin/env python3
"""Claude Code delegate server for Hermes Agent.

Exposes a single MCP tool, delegate_coding_task, that runs the Claude Code CLI on
the Pi host to carry out a coding task inside a cloned GitHub repo. Hermes (running
in the Docker container with network_mode: host) reaches this over plain HTTP on
localhost, so the `claude`/`gh` processes and their credentials stay on the host and
are never baked into the Hermes image or affected by `docker compose pull`.

Deliberately does NOT pass --bare: bare mode skips OAuth/keychain reads entirely and
requires ANTHROPIC_API_KEY instead, which would defeat the point of authenticating
with a Claude subscription rather than API billing.
"""

import json
import os
import subprocess
from pathlib import Path

from mcp.server.fastmcp import FastMCP

DELEGATE_PORT = int(os.environ.get("CLAUDE_DELEGATE_PORT", "5556"))
WORKSPACE_ROOT = Path(
    os.environ.get("CLAUDE_DELEGATE_WORKSPACE", str(Path.home() / "coding-workspace"))
)
TASK_TIMEOUT_SECONDS = int(os.environ.get("CLAUDE_DELEGATE_TIMEOUT", "1200"))

mcp = FastMCP(
    "claude-code-delegate",
    host="127.0.0.1",
    port=DELEGATE_PORT,
    stateless_http=True,
)


def _repo_dir(repo: str) -> Path:
    """Map an "owner/repo" string to its clone path under the workspace root."""
    owner, _, name = repo.partition("/")
    if not owner or not name:
        raise ValueError(f"repo must be 'owner/repo', got: {repo!r}")
    return WORKSPACE_ROOT / owner / name


def _ensure_repo(repo: str) -> Path:
    """Clone the repo on first use, or pull it fresh if already present."""
    repo_dir = _repo_dir(repo)
    if repo_dir.exists():
        # Best-effort: a previous task may have left local changes, so a failed
        # fast-forward pull should not block this task from running against
        # whatever is already checked out.
        subprocess.run(
            ["git", "-C", str(repo_dir), "pull", "--ff-only"],
            capture_output=True,
            text=True,
            timeout=60,
        )
        return repo_dir

    repo_dir.parent.mkdir(parents=True, exist_ok=True)
    result = subprocess.run(
        ["gh", "repo", "clone", repo, str(repo_dir)],
        capture_output=True,
        text=True,
        timeout=120,
    )
    if result.returncode != 0:
        raise RuntimeError(f"gh repo clone failed for {repo}: {result.stderr.strip()}")
    return repo_dir


@mcp.tool()
def delegate_coding_task(repo: str, task: str) -> str:
    """Delegate a coding task to the Claude Code CLI running on the Pi host.

    Use this whenever the user asks for real coding work (implementing a feature,
    fixing a bug, refactoring, writing tests) in a GitHub repository they have
    access to — Claude Code is a dedicated coding agent and does a more thorough
    job than answering inline. Don't use it for quick questions, explanations, or
    anything that doesn't need to touch a repo's files.

    Args:
        repo: GitHub repository as "owner/repo" (e.g. "PapaDanielVi/hermes-pi").
            Cloned automatically on first use via `gh`, and pulled fresh on every
            subsequent call.
        task: A clear, complete description of what to do. Claude Code runs
            unattended with full tool access (file edits, shell commands, git/gh)
            and no human present to approve anything, so be explicit about scope
            (e.g. "open a PR" vs "just commit to main").

    Returns:
        Claude Code's final result message as plain text, or an error message
        starting with "ERROR:" if the task could not be run.
    """
    try:
        repo_dir = _ensure_repo(repo)
    except Exception as exc:
        return f"ERROR: could not prepare {repo}: {exc}"

    try:
        proc = subprocess.run(
            [
                "claude",
                "--dangerously-skip-permissions",
                "-p",
                task,
                "--output-format",
                "json",
            ],
            cwd=str(repo_dir),
            capture_output=True,
            text=True,
            timeout=TASK_TIMEOUT_SECONDS,
        )
    except subprocess.TimeoutExpired:
        return f"ERROR: Claude Code did not finish within {TASK_TIMEOUT_SECONDS}s."

    if proc.returncode != 0:
        return f"ERROR: Claude Code exited {proc.returncode}: {proc.stderr.strip()[:2000]}"

    try:
        payload = json.loads(proc.stdout)
    except json.JSONDecodeError:
        return proc.stdout.strip() or f"ERROR: empty output (stderr: {proc.stderr.strip()[:2000]})"

    if payload.get("error"):
        return f"ERROR: {payload['error']}"

    result = payload.get("result", "").strip()
    cost = payload.get("total_cost_usd")
    if cost is not None:
        return f"{result}\n\n(Claude Code session cost: ${cost:.4f})"
    return result


if __name__ == "__main__":
    mcp.run(transport="streamable-http")
