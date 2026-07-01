#!/usr/bin/env python3
"""Export Telegram sessions from Hermes state.db to per-user markdown files.

Hermes stores sessions in two tables: `sessions` (one row per session, with a
`source` column like "telegram" and identity columns such as `user_id` /
`chat_id`) and `messages` (one row per message, linked by `session_id`).
Older revisions of this script assumed a single denormalized `sessions` table
with the columns `session_id`/`created_at`/`messages`, which does not match
that schema and made every export crash. Column presence is checked at
runtime so a future schema change degrades gracefully instead of taking the
whole sync down with it.
"""

import argparse
import os
import sqlite3
import sys
from datetime import datetime
from pathlib import Path

MAX_SESSIONS_PER_USER = 30
MAX_MESSAGES_PREVIEW = 5
MAX_CONTENT_CHARS = 200


def table_columns(conn: sqlite3.Connection, table: str) -> set[str]:
    """Return the column names present on a table, or an empty set if it does not exist."""
    cursor = conn.cursor()
    cursor.execute(f"PRAGMA table_info({table})")
    return {row[1] for row in cursor.fetchall()}


def get_user_sessions(conn: sqlite3.Connection, user_id: int, session_cols: set[str]) -> list[sqlite3.Row]:
    """Fetch Telegram sessions belonging to a user, identified by user_id or chat_id."""
    identity_clauses = []
    params: list = []
    for col in ("user_id", "chat_id"):
        if col in session_cols:
            identity_clauses.append(f"{col} = ?")
            params.append(str(user_id))

    if not identity_clauses:
        return []

    where = f"source = 'telegram' AND ({' OR '.join(identity_clauses)})"
    cursor = conn.cursor()
    cursor.execute(
        f"""
        SELECT id, started_at, title
        FROM sessions
        WHERE {where}
        ORDER BY started_at DESC
        LIMIT ?
        """,
        (*params, MAX_SESSIONS_PER_USER),
    )
    return cursor.fetchall()


def get_session_messages(conn: sqlite3.Connection, session_id: str) -> list[sqlite3.Row]:
    """Fetch the first few messages of a session for a preview."""
    cursor = conn.cursor()
    cursor.execute(
        """
        SELECT role, content
        FROM messages
        WHERE session_id = ?
        ORDER BY timestamp ASC
        LIMIT ?
        """,
        (session_id, MAX_MESSAGES_PREVIEW),
    )
    return cursor.fetchall()


def get_allowed_users(env_path: str) -> list[int]:
    """Parse TELEGRAM_ALLOWED_USERS from .env file."""
    users = []
    if os.path.exists(env_path):
        with open(env_path) as f:
            for line in f:
                if line.startswith("TELEGRAM_ALLOWED_USERS="):
                    value = line.split("=", 1)[1].strip()
                    users = [int(u.strip()) for u in value.split(",") if u.strip().isdigit()]
    return users


def export_sessions(db_path: str, output_dir: str) -> None:
    """Export sessions to markdown files organized by user ID."""
    if not os.path.exists(db_path):
        print(f"[export] Database not found: {db_path}")
        return

    conn = sqlite3.connect(db_path)
    conn.row_factory = sqlite3.Row

    session_cols = table_columns(conn, "sessions")
    if not session_cols:
        print("[export] No 'sessions' table found in state.db — nothing to export.")
        conn.close()
        return

    repo_dir = Path(__file__).parent.parent
    env_path = repo_dir / ".env"
    users = get_allowed_users(str(env_path))

    if not users and "user_id" in session_cols:
        cursor = conn.cursor()
        cursor.execute("SELECT DISTINCT user_id FROM sessions WHERE user_id IS NOT NULL")
        users = [row[0] for row in cursor.fetchall() if str(row[0]).isdigit()]
        users = [int(u) for u in users]

    for user_id in users:
        user_dir = Path(output_dir) / "users" / str(user_id)
        user_dir.mkdir(parents=True, exist_ok=True)

        profile_path = user_dir / "profile.md"
        with open(profile_path, "w") as f:
            f.write("# User Profile\n\n")
            f.write(f"Telegram ID: `{user_id}`\n\n")
            f.write(f"Last updated: {datetime.now().isoformat()}\n")

        sessions = get_user_sessions(conn, user_id, session_cols)
        sessions_path = user_dir / "sessions.md"
        with open(sessions_path, "w") as f:
            f.write("# Session History (Last 30 Days)\n\n")
            f.write(f"Telegram ID: `{user_id}`\n\n")
            for session in sessions:
                started_at = session["started_at"]
                try:
                    created = datetime.fromtimestamp(started_at).isoformat() if started_at else "unknown"
                except (TypeError, ValueError, OSError):
                    created = str(started_at) if started_at else "unknown"
                title = session["title"] if "title" in session.keys() and session["title"] else "(untitled)"
                f.write(f"## Session: {created} — {title}\n\n")

                messages = get_session_messages(conn, session["id"])
                if not messages:
                    f.write("_No message preview available_\n")
                for msg in messages:
                    role = msg["role"] or "unknown"
                    content = msg["content"] or ""
                    preview = content[:MAX_CONTENT_CHARS] + "..." if len(content) > MAX_CONTENT_CHARS else content
                    f.write(f"- **{role}**: {preview}\n")
                f.write("\n")

    conn.close()
    print(f"[export] Exported sessions for {len(users)} users")


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description="Export Hermes sessions to markdown")
    parser.add_argument("db_path", help="Path to state.db")
    parser.add_argument("output_dir", help="Output directory for memory files")

    args = parser.parse_args()

    try:
        export_sessions(args.db_path, args.output_dir)
    except sqlite3.Error as e:
        # A schema mismatch here must not take down the whole memory sync —
        # skills and shared memory still need to be committed and pushed.
        print(f"[export] Session export failed ({e}); skipping session export this run.")
        sys.exit(0)

    sys.exit(0)
