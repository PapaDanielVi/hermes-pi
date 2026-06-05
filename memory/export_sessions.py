#!/usr/bin/env python3
"""
Export sessions from Hermes state.db to per-user markdown files.

This script reads the SQLite database and creates markdown files for each
Telegram user, containing their profile and recent session summaries.
"""

import argparse
import json
import os
import sqlite3
import sys
from datetime import datetime, timedelta
from pathlib import Path


def get_user_sessions(conn: sqlite3.Connection, user_id: int) -> list[dict]:
    """Fetch all sessions for a given Telegram user ID."""
    cursor = conn.cursor()
    cursor.execute(
        """
        SELECT session_id, created_at, messages
        FROM sessions
        WHERE user_id = ?
        ORDER BY created_at DESC
        LIMIT 30
        """,
        (user_id,),
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

    # Get all users from sessions or from .env
    repo_dir = Path(__file__).parent.parent
    env_path = repo_dir / ".env"
    users = get_allowed_users(str(env_path))

    # If no users from .env, query the database
    if not users:
        cursor = conn.cursor()
        cursor.execute("SELECT DISTINCT user_id FROM sessions")
        users = [row[0] for row in cursor.fetchall()]

    for user_id in users:
        user_dir = Path(output_dir) / "users" / str(user_id)
        user_dir.mkdir(parents=True, exist_ok=True)

        # Export profile
        profile_path = user_dir / "profile.md"
        with open(profile_path, "w") as f:
            f.write(f"# User Profile\n\n")
            f.write(f"Telegram ID: `{user_id}`\n\n")
            f.write(f"Last updated: {datetime.now().isoformat()}\n")

        # Export sessions
        sessions = get_user_sessions(conn, user_id)
        sessions_path = user_dir / "sessions.md"
        with open(sessions_path, "w") as f:
            f.write(f"# Session History (Last 30 Days)\n\n")
            f.write(f"Telegram ID: `{user_id}`\n\n")
            for session in sessions:
                created = session["created_at"] or "unknown"
                f.write(f"## Session: {created}\n\n")
                # Try to extract summary from messages if available
                try:
                    messages = json.loads(session["messages"] or "[]")
                    if messages:
                        # Write first few messages as context
                        for msg in messages[:5]:
                            role = msg.get("role", "unknown")
                            content = msg.get("content", "")
                            # Truncate for summary
                            preview = content[:200] + "..." if len(content) > 200 else content
                            f.write(f"- **{role}**: {preview}\n")
                except (json.JSONDecodeError, TypeError):
                    f.write("_Session data unavailable_\n")
                f.write("\n")

    conn.close()
    print(f"[export] Exported sessions for {len(users)} users")


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description="Export Hermes sessions to markdown")
    parser.add_argument("db_path", help="Path to state.db")
    parser.add_argument("output_dir", help="Output directory for memory files")

    args = parser.parse_args()
    export_sessions(args.db_path, args.output_dir)

    sys.exit(0)