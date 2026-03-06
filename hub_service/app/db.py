from __future__ import annotations

import json
import sqlite3
from contextlib import contextmanager
from pathlib import Path
from typing import Iterator, Optional


class Database:
    def __init__(self, path: Path):
        self.path = path

    @contextmanager
    def connect(self) -> Iterator[sqlite3.Connection]:
        self.path.parent.mkdir(parents=True, exist_ok=True)
        conn = sqlite3.connect(self.path)
        conn.row_factory = sqlite3.Row
        conn.execute("PRAGMA journal_mode=WAL;")
        conn.execute("PRAGMA foreign_keys=ON;")
        try:
            yield conn
            conn.commit()
        finally:
            conn.close()

    def init_schema(self) -> None:
        with self.connect() as conn:
            conn.executescript(
                """
                CREATE TABLE IF NOT EXISTS projects (
                    project_id TEXT PRIMARY KEY,
                    name TEXT NOT NULL,
                    project_path TEXT NOT NULL,
                    unity_path TEXT NOT NULL,
                    unity_version TEXT,
                    tags_json TEXT NOT NULL,
                    status TEXT NOT NULL,
                    last_seen_at TEXT,
                    created_at TEXT NOT NULL,
                    updated_at TEXT NOT NULL
                );

                CREATE TABLE IF NOT EXISTS sessions (
                    session_id TEXT PRIMARY KEY,
                    client_id TEXT NOT NULL,
                    project_id TEXT NOT NULL,
                    status TEXT NOT NULL,
                    lease_expires_at TEXT NOT NULL,
                    launch_token TEXT NOT NULL,
                    agent_token TEXT,
                    agent_endpoint TEXT,
                    unity_pid INTEGER,
                    tool_manifest_json TEXT,
                    heartbeat_at TEXT,
                    created_at TEXT NOT NULL,
                    updated_at TEXT NOT NULL,
                    FOREIGN KEY(project_id) REFERENCES projects(project_id)
                );

                CREATE INDEX IF NOT EXISTS idx_sessions_client_id ON sessions(client_id);
                CREATE INDEX IF NOT EXISTS idx_sessions_project_id ON sessions(project_id);
                """
            )
            project_columns = [
                row["name"]
                for row in conn.execute("PRAGMA table_info(projects)").fetchall()
            ]
            if "unity_version" not in project_columns:
                conn.execute("ALTER TABLE projects ADD COLUMN unity_version TEXT")
            session_columns = [
                row["name"]
                for row in conn.execute("PRAGMA table_info(sessions)").fetchall()
            ]
            if "unity_pid" not in session_columns:
                conn.execute("ALTER TABLE sessions ADD COLUMN unity_pid INTEGER")


def encode_json(value: object) -> str:
    return json.dumps(value, separators=(",", ":"), sort_keys=True)

def decode_json(text: Optional[str], fallback: object) -> object:
    if not text:
        return fallback
    return json.loads(text)
