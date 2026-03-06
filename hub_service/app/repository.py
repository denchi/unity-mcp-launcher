from __future__ import annotations

from datetime import datetime, timezone
from typing import Optional
from uuid import uuid4

from .db import Database, decode_json, encode_json
from .models import ProjectCreateRequest, ProjectRecord, SessionRecord


def now_iso() -> str:
    return datetime.now(timezone.utc).isoformat()


def parse_dt(raw: Optional[str]) -> Optional[datetime]:
    if raw is None:
        return None
    return datetime.fromisoformat(raw)


class HubRepository:
    def __init__(self, db: Database):
        self.db = db

    def upsert_project(self, payload: ProjectCreateRequest) -> ProjectRecord:
        stamp = now_iso()
        with self.db.connect() as conn:
            existing = conn.execute(
                "SELECT created_at FROM projects WHERE project_id = ?",
                (payload.project_id,),
            ).fetchone()
            created_at = existing["created_at"] if existing else stamp
            conn.execute(
                """
                INSERT INTO projects (project_id, name, project_path, unity_path, tags_json, status, last_seen_at, created_at, updated_at)
                VALUES (?, ?, ?, ?, ?, 'idle', NULL, ?, ?)
                ON CONFLICT(project_id) DO UPDATE SET
                    name = excluded.name,
                    project_path = excluded.project_path,
                    unity_path = excluded.unity_path,
                    tags_json = excluded.tags_json,
                    updated_at = excluded.updated_at
                """,
                (
                    payload.project_id,
                    payload.name,
                    payload.project_path,
                    payload.unity_path,
                    encode_json(payload.tags),
                    created_at,
                    stamp,
                ),
            )

        return self.get_project(payload.project_id)

    def get_project(self, project_id: str) -> Optional[ProjectRecord]:
        with self.db.connect() as conn:
            row = conn.execute(
                "SELECT * FROM projects WHERE project_id = ?",
                (project_id,),
            ).fetchone()
        return self._project_from_row(row) if row else None

    def list_projects(self) -> list[ProjectRecord]:
        with self.db.connect() as conn:
            rows = conn.execute(
                "SELECT * FROM projects ORDER BY updated_at DESC"
            ).fetchall()
        return [self._project_from_row(r) for r in rows]

    def delete_project(self, project_id: str) -> bool:
        with self.db.connect() as conn:
            conn.execute(
                "DELETE FROM sessions WHERE project_id = ?",
                (project_id,),
            )
            deleted = conn.execute(
                "DELETE FROM projects WHERE project_id = ?",
                (project_id,),
            )
        return deleted.rowcount > 0

    def find_project(
        self,
        project_id: Optional[str],
        name: Optional[str],
        tags: list[str],
        most_recent: bool,
    ) -> Optional[ProjectRecord]:
        projects = self.list_projects()
        if project_id:
            return next((p for p in projects if p.project_id == project_id), None)
        if name:
            lowered = name.strip().lower()
            return next((p for p in projects if p.name.lower() == lowered), None)
        if tags:
            wanted = {t.strip().lower() for t in tags if t.strip()}
            for project in projects:
                present = {t.lower() for t in project.tags}
                if wanted.issubset(present):
                    return project
        if most_recent and projects:
            return projects[0]
        return projects[0] if projects else None

    def create_session(
        self,
        client_id: str,
        project_id: str,
        status: str,
        lease_expires_at: datetime,
    ) -> SessionRecord:
        stamp = now_iso()
        session_id = str(uuid4())
        launch_token = str(uuid4())
        with self.db.connect() as conn:
            conn.execute(
                """
                INSERT INTO sessions (
                    session_id, client_id, project_id, status, lease_expires_at,
                    launch_token, agent_token, agent_endpoint, unity_pid, tool_manifest_json,
                    heartbeat_at, created_at, updated_at
                ) VALUES (?, ?, ?, ?, ?, ?, NULL, NULL, NULL, '{}', NULL, ?, ?)
                """,
                (
                    session_id,
                    client_id,
                    project_id,
                    status,
                    lease_expires_at.isoformat(),
                    launch_token,
                    stamp,
                    stamp,
                ),
            )
            conn.execute(
                "UPDATE projects SET status = ?, updated_at = ? WHERE project_id = ?",
                ("starting" if status == "starting" else "ready", stamp, project_id),
            )
        return self.get_session(session_id)

    def set_session_unity_pid(self, session_id: str, unity_pid: int) -> Optional[SessionRecord]:
        with self.db.connect() as conn:
            conn.execute(
                "UPDATE sessions SET unity_pid = ?, updated_at = ? WHERE session_id = ?",
                (unity_pid, now_iso(), session_id),
            )
        return self.get_session(session_id)

    def list_sessions(self, client_id: Optional[str] = None, include_dead: bool = False) -> list[SessionRecord]:
        query = "SELECT * FROM sessions"
        clauses: list[str] = []
        params: list[str] = []
        if client_id:
            clauses.append("client_id = ?")
            params.append(client_id)
        if not include_dead:
            clauses.append("status != 'dead'")
        if clauses:
            query += " WHERE " + " AND ".join(clauses)
        query += " ORDER BY updated_at DESC"

        with self.db.connect() as conn:
            rows = conn.execute(query, tuple(params)).fetchall()
        return [self._session_from_row(row) for row in rows]

    def list_stale_ready_sessions(self, stale_before: datetime) -> list[SessionRecord]:
        with self.db.connect() as conn:
            rows = conn.execute(
                """
                SELECT * FROM sessions
                WHERE status = 'ready'
                  AND heartbeat_at IS NOT NULL
                  AND heartbeat_at < ?
                ORDER BY updated_at ASC
                """,
                (stale_before.isoformat(),),
            ).fetchall()
        return [self._session_from_row(row) for row in rows]

    def get_session(self, session_id: str) -> Optional[SessionRecord]:
        with self.db.connect() as conn:
            row = conn.execute(
                "SELECT * FROM sessions WHERE session_id = ?",
                (session_id,),
            ).fetchone()
        return self._session_from_row(row) if row else None

    def mark_project_status(self, project_id: str, status: str) -> None:
        with self.db.connect() as conn:
            conn.execute(
                "UPDATE projects SET status = ?, updated_at = ? WHERE project_id = ?",
                (status, now_iso(), project_id),
            )

    def register_agent(
        self,
        session_id: str,
        endpoint: str,
        tool_manifest: dict,
    ) -> Optional[SessionRecord]:
        stamp = now_iso()
        agent_token = str(uuid4())
        with self.db.connect() as conn:
            row = conn.execute(
                "SELECT project_id FROM sessions WHERE session_id = ?",
                (session_id,),
            ).fetchone()
            if not row:
                return None
            project_id = row["project_id"]
            conn.execute(
                """
                UPDATE sessions
                SET status = 'ready',
                    agent_endpoint = ?,
                    tool_manifest_json = ?,
                    agent_token = ?,
                    heartbeat_at = ?,
                    updated_at = ?
                WHERE session_id = ?
                """,
                (
                    endpoint,
                    encode_json(tool_manifest),
                    agent_token,
                    stamp,
                    stamp,
                    session_id,
                ),
            )
            conn.execute(
                "UPDATE projects SET status = 'ready', last_seen_at = ?, updated_at = ? WHERE project_id = ?",
                (stamp, stamp, project_id),
            )
        updated = self.get_session(session_id)
        return updated

    def touch_heartbeat(self, session_id: str) -> Optional[SessionRecord]:
        stamp = now_iso()
        with self.db.connect() as conn:
            row = conn.execute(
                "SELECT project_id FROM sessions WHERE session_id = ?",
                (session_id,),
            ).fetchone()
            if not row:
                return None
            conn.execute(
                "UPDATE sessions SET heartbeat_at = ?, updated_at = ? WHERE session_id = ?",
                (stamp, stamp, session_id),
            )
            conn.execute(
                "UPDATE projects SET last_seen_at = ?, updated_at = ? WHERE project_id = ?",
                (stamp, stamp, row["project_id"]),
            )
        return self.get_session(session_id)

    def extend_lease(self, session_id: str, lease_expires_at: datetime) -> Optional[SessionRecord]:
        with self.db.connect() as conn:
            conn.execute(
                "UPDATE sessions SET lease_expires_at = ?, updated_at = ? WHERE session_id = ?",
                (lease_expires_at.isoformat(), now_iso(), session_id),
            )
        return self.get_session(session_id)

    def expire_old_sessions(self, now: datetime) -> int:
        stamp = now.isoformat()
        with self.db.connect() as conn:
            sessions = conn.execute(
                "SELECT session_id, project_id FROM sessions WHERE status != 'dead' AND lease_expires_at < ?",
                (stamp,),
            ).fetchall()
            for session in sessions:
                conn.execute(
                    "UPDATE sessions SET status = 'dead', updated_at = ? WHERE session_id = ?",
                    (stamp, session["session_id"]),
                )
                conn.execute(
                    "UPDATE projects SET status = 'dead', updated_at = ? WHERE project_id = ?",
                    (stamp, session["project_id"]),
                )
            return len(sessions)

    def expire_stale_heartbeats(self, stale_before: datetime) -> int:
        stamp = now_iso()
        with self.db.connect() as conn:
            sessions = conn.execute(
                """
                SELECT session_id, project_id
                FROM sessions
                WHERE status = 'ready'
                  AND heartbeat_at IS NOT NULL
                  AND heartbeat_at < ?
                """,
                (stale_before.isoformat(),),
            ).fetchall()
            for session in sessions:
                conn.execute(
                    "UPDATE sessions SET status = 'dead', updated_at = ? WHERE session_id = ?",
                    (stamp, session["session_id"]),
                )
                conn.execute(
                    "UPDATE projects SET status = 'dead', updated_at = ? WHERE project_id = ?",
                    (stamp, session["project_id"]),
                )
            return len(sessions)

    def kill_session(self, session_id: str) -> Optional[SessionRecord]:
        stamp = now_iso()
        with self.db.connect() as conn:
            row = conn.execute(
                "SELECT project_id FROM sessions WHERE session_id = ?",
                (session_id,),
            ).fetchone()
            if not row:
                return None
            conn.execute(
                """
                UPDATE sessions
                SET status = 'dead',
                    agent_token = NULL,
                    agent_endpoint = NULL,
                    unity_pid = NULL,
                    updated_at = ?
                WHERE session_id = ?
                """,
                (stamp, session_id),
            )
            conn.execute(
                "UPDATE projects SET status = 'dead', updated_at = ? WHERE project_id = ?",
                (stamp, row["project_id"]),
            )
        return self.get_session(session_id)

    def get_active_session_for_project(self, project_id: str) -> Optional[SessionRecord]:
        with self.db.connect() as conn:
            row = conn.execute(
                """
                SELECT *
                FROM sessions
                WHERE project_id = ?
                  AND status != 'dead'
                ORDER BY
                    CASE status
                        WHEN 'ready' THEN 0
                        WHEN 'starting' THEN 1
                        ELSE 2
                    END ASC,
                    updated_at DESC
                LIMIT 1
                """,
                (project_id,),
            ).fetchone()
        return self._session_from_row(row) if row else None

    def has_non_dead_session_for_project(self, project_id: str, exclude_session_id: Optional[str] = None) -> bool:
        query = "SELECT 1 FROM sessions WHERE project_id = ? AND status != 'dead'"
        params: list[str] = [project_id]
        if exclude_session_id:
            query += " AND session_id != ?"
            params.append(exclude_session_id)
        query += " LIMIT 1"

        with self.db.connect() as conn:
            row = conn.execute(query, tuple(params)).fetchone()
        return row is not None

    def revive_session_from_heartbeat(self, session_id: str, lease_expires_at: datetime) -> Optional[SessionRecord]:
        stamp = now_iso()
        with self.db.connect() as conn:
            row = conn.execute(
                "SELECT project_id FROM sessions WHERE session_id = ?",
                (session_id,),
            ).fetchone()
            if not row:
                return None

            conn.execute(
                """
                UPDATE sessions
                SET status = 'ready',
                    lease_expires_at = ?,
                    heartbeat_at = ?,
                    updated_at = ?
                WHERE session_id = ?
                """,
                (lease_expires_at.isoformat(), stamp, stamp, session_id),
            )
            conn.execute(
                "UPDATE projects SET status = 'ready', last_seen_at = ?, updated_at = ? WHERE project_id = ?",
                (stamp, stamp, row["project_id"]),
            )
        return self.get_session(session_id)

    def _project_from_row(self, row) -> ProjectRecord:
        return ProjectRecord(
            project_id=row["project_id"],
            name=row["name"],
            project_path=row["project_path"],
            unity_path=row["unity_path"],
            tags=decode_json(row["tags_json"], []),
            status=row["status"],
            last_seen_at=parse_dt(row["last_seen_at"]),
            created_at=parse_dt(row["created_at"]),
            updated_at=parse_dt(row["updated_at"]),
        )

    def _session_from_row(self, row) -> SessionRecord:
        return SessionRecord(
            session_id=row["session_id"],
            client_id=row["client_id"],
            project_id=row["project_id"],
            status=row["status"],
            lease_expires_at=parse_dt(row["lease_expires_at"]),
            launch_token=row["launch_token"],
            agent_token=row["agent_token"],
            agent_endpoint=row["agent_endpoint"],
            unity_pid=row["unity_pid"],
            tool_manifest=decode_json(row["tool_manifest_json"], {}),
            heartbeat_at=parse_dt(row["heartbeat_at"]),
            created_at=parse_dt(row["created_at"]),
            updated_at=parse_dt(row["updated_at"]),
        )
