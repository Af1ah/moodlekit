#!/usr/bin/env python3
"""Small non-secret SQLite index for MoodleKit sites and long-running operations."""

from __future__ import annotations

import argparse
import json
import os
import sqlite3
import sys
import uuid
from datetime import datetime, timezone
from pathlib import Path


def now() -> str:
    return datetime.now(timezone.utc).isoformat()


def connect(path: str) -> sqlite3.Connection:
    db_path = Path(path)
    db_path.parent.mkdir(mode=0o700, parents=True, exist_ok=True)
    conn = sqlite3.connect(db_path, timeout=10)
    conn.row_factory = sqlite3.Row
    conn.executescript(
        """
        PRAGMA journal_mode=WAL;
        PRAGMA synchronous=NORMAL;
        CREATE TABLE IF NOT EXISTS operations (
            id TEXT PRIMARY KEY,
            kind TEXT NOT NULL,
            slug TEXT NOT NULL,
            status TEXT NOT NULL,
            current_step TEXT NOT NULL DEFAULT '',
            message TEXT NOT NULL DEFAULT '',
            metadata_json TEXT NOT NULL DEFAULT '{}',
            started_at TEXT NOT NULL,
            updated_at TEXT NOT NULL,
            finished_at TEXT
        );
        CREATE INDEX IF NOT EXISTS operations_slug_updated
            ON operations(slug, updated_at DESC);
        CREATE TABLE IF NOT EXISTS sites (
            slug TEXT PRIMARY KEY,
            domain TEXT NOT NULL DEFAULT '',
            moodle_dir TEXT NOT NULL DEFAULT '',
            moodledata_dir TEXT NOT NULL DEFAULT '',
            db_type TEXT NOT NULL DEFAULT '',
            db_name TEXT NOT NULL DEFAULT '',
            php_version TEXT NOT NULL DEFAULT '',
            moodle_version TEXT NOT NULL DEFAULT '',
            is_moodle5 INTEGER NOT NULL DEFAULT 0,
            source_updated_at TEXT NOT NULL DEFAULT '',
            updated_at TEXT NOT NULL
        );
        """
    )
    os.chmod(db_path, 0o600)
    return conn


def parse_object(raw: str) -> dict:
    value = json.loads(raw)
    if not isinstance(value, dict):
        raise ValueError("JSON value must be an object")
    return value


def redact_secrets(value):
    sensitive = {"password", "pass", "db_pass", "token", "secret", "api_key", "key"}
    if isinstance(value, dict):
        return {
            key: "[redacted]" if key.lower() in sensitive else redact_secrets(item)
            for key, item in value.items()
        }
    if isinstance(value, list):
        return [redact_secrets(item) for item in value]
    return value


def start_operation(conn: sqlite3.Connection, args: argparse.Namespace) -> None:
    operation_id = str(uuid.uuid4())
    timestamp = now()
    metadata = redact_secrets(parse_object(args.metadata_json))
    conn.execute(
        "INSERT INTO operations "
        "(id, kind, slug, status, metadata_json, started_at, updated_at) "
        "VALUES (?, ?, ?, 'running', ?, ?, ?)",
        (operation_id, args.kind, args.slug, json.dumps(metadata), timestamp, timestamp),
    )
    conn.commit()
    print(operation_id)


def update_operation(conn: sqlite3.Connection, args: argparse.Namespace) -> None:
    timestamp = now()
    finished_at = timestamp if args.status in {"completed", "failed", "cancelled"} else None
    cursor = conn.execute(
        "UPDATE operations SET status=?, "
        "current_step=CASE WHEN ?='' THEN current_step ELSE ? END, "
        "message=CASE WHEN ?='' THEN message ELSE ? END, updated_at=?, "
        "finished_at=COALESCE(?, finished_at) WHERE id=?",
        (
            args.status,
            args.step,
            args.step,
            args.message,
            args.message,
            timestamp,
            finished_at,
            args.id,
        ),
    )
    if cursor.rowcount != 1:
        raise ValueError(f"operation not found: {args.id}")
    conn.commit()


def upsert_site(conn: sqlite3.Connection, args: argparse.Namespace) -> None:
    data = parse_object(args.json)
    slug = str(data.get("slug", "")).strip()
    if not slug:
        raise ValueError("site JSON requires a slug")
    values = (
        slug,
        str(data.get("domain", "")),
        str(data.get("moodle_dir", "")),
        str(data.get("moodledata_dir", "")),
        str(data.get("db_type", "")),
        str(data.get("db_name", "")),
        str(data.get("php_version", "")),
        str(data.get("moodle_version", "")),
        1 if data.get("is_moodle5") in (True, 1, "1") else 0,
        str(data.get("upgraded_at") or data.get("created_at") or data.get("source_updated_at") or ""),
        now(),
    )
    conn.execute(
        """
        INSERT INTO sites
          (slug, domain, moodle_dir, moodledata_dir, db_type, db_name,
           php_version, moodle_version, is_moodle5, source_updated_at, updated_at)
        VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
        ON CONFLICT(slug) DO UPDATE SET
          domain=excluded.domain, moodle_dir=excluded.moodle_dir,
          moodledata_dir=excluded.moodledata_dir, db_type=excluded.db_type,
          db_name=excluded.db_name, php_version=excluded.php_version,
          moodle_version=excluded.moodle_version, is_moodle5=excluded.is_moodle5,
          source_updated_at=excluded.source_updated_at, updated_at=excluded.updated_at
        """,
        values,
    )
    conn.commit()


def emit_rows(rows: list[sqlite3.Row]) -> None:
    print(json.dumps([dict(row) for row in rows], separators=(",", ":")))


def main() -> int:
    os.umask(0o077)
    parser = argparse.ArgumentParser()
    parser.add_argument("--db", required=True)
    sub = parser.add_subparsers(dest="command", required=True)

    sub.add_parser("init")
    start = sub.add_parser("operation-start")
    start.add_argument("--kind", required=True)
    start.add_argument("--slug", required=True)
    start.add_argument("--metadata-json", default="{}")
    update = sub.add_parser("operation-update")
    update.add_argument("--id", required=True)
    update.add_argument("--status", required=True)
    update.add_argument("--step", default="")
    update.add_argument("--message", default="")
    site = sub.add_parser("site-upsert")
    site.add_argument("--json", required=True)
    delete_site = sub.add_parser("site-delete")
    delete_site.add_argument("--slug", required=True)
    sub.add_parser("site-list")
    latest = sub.add_parser("operation-latest")
    latest.add_argument("--slug", required=True)

    args = parser.parse_args()
    try:
        with connect(args.db) as conn:
            if args.command == "operation-start":
                start_operation(conn, args)
            elif args.command == "operation-update":
                update_operation(conn, args)
            elif args.command == "site-upsert":
                upsert_site(conn, args)
            elif args.command == "site-delete":
                conn.execute("DELETE FROM sites WHERE slug=?", (args.slug,))
                conn.commit()
            elif args.command == "site-list":
                emit_rows(conn.execute("SELECT * FROM sites ORDER BY slug").fetchall())
            elif args.command == "operation-latest":
                rows = conn.execute(
                    "SELECT * FROM operations WHERE slug=? ORDER BY updated_at DESC LIMIT 1",
                    (args.slug,),
                ).fetchall()
                emit_rows(rows)
        return 0
    except (OSError, sqlite3.Error, ValueError, json.JSONDecodeError) as exc:
        print(f"state index error: {exc}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
