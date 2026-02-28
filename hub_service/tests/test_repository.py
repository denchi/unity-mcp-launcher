from __future__ import annotations

import tempfile
import unittest
from datetime import datetime, timedelta, timezone
from pathlib import Path

from app.db import Database
from app.models import ProjectCreateRequest
from app.repository import HubRepository


class HubRepositoryTests(unittest.TestCase):
    def setUp(self) -> None:
        self.temp_dir = tempfile.TemporaryDirectory()
        db_path = Path(self.temp_dir.name) / "test.db"
        self.db = Database(db_path)
        self.db.init_schema()
        self.repo = HubRepository(self.db)

    def tearDown(self) -> None:
        self.temp_dir.cleanup()

    def test_upsert_and_select_project(self) -> None:
        created = self.repo.upsert_project(
            ProjectCreateRequest(
                project_id="p1",
                name="LumenInferius",
                project_path="/tmp/p1",
                unity_path="/Applications/Unity",
                tags=["shader", "prototype"],
            )
        )
        self.assertEqual(created.project_id, "p1")

        found = self.repo.find_project(None, "LumenInferius", [], False)
        self.assertIsNotNone(found)
        self.assertEqual(found.project_id, "p1")

    def test_session_create_register_and_heartbeat(self) -> None:
        self.repo.upsert_project(
            ProjectCreateRequest(
                project_id="p2",
                name="Dungeon",
                project_path="/tmp/p2",
                unity_path="/Applications/Unity",
                tags=[],
            )
        )
        session = self.repo.create_session(
            client_id="client-a",
            project_id="p2",
            status="starting",
            lease_expires_at=datetime.now(timezone.utc) + timedelta(minutes=5),
        )
        self.assertEqual(session.status, "starting")

        registered = self.repo.register_agent(session.session_id, "http://127.0.0.1:9900", {"tools": ["ping"]})
        self.assertIsNotNone(registered)
        self.assertEqual(registered.status, "ready")
        self.assertIsNotNone(registered.agent_token)

        heartbeat = self.repo.touch_heartbeat(session.session_id)
        self.assertIsNotNone(heartbeat)
        self.assertIsNotNone(heartbeat.heartbeat_at)

    def test_expire_old_sessions(self) -> None:
        self.repo.upsert_project(
            ProjectCreateRequest(
                project_id="p3",
                name="Arena",
                project_path="/tmp/p3",
                unity_path="/Applications/Unity",
                tags=[],
            )
        )
        session = self.repo.create_session(
            client_id="client-b",
            project_id="p3",
            status="ready",
            lease_expires_at=datetime.now(timezone.utc) - timedelta(seconds=1),
        )

        expired = self.repo.expire_old_sessions(datetime.now(timezone.utc))
        self.assertEqual(expired, 1)

        dead = self.repo.get_session(session.session_id)
        self.assertEqual(dead.status, "dead")

    def test_delete_project(self) -> None:
        self.repo.upsert_project(
            ProjectCreateRequest(
                project_id="p4",
                name="DeleteMe",
                project_path="/tmp/p4",
                unity_path="/Applications/Unity",
                tags=[],
            )
        )
        deleted = self.repo.delete_project("p4")
        self.assertTrue(deleted)
        self.assertIsNone(self.repo.get_project("p4"))

    def test_expire_stale_heartbeats(self) -> None:
        self.repo.upsert_project(
            ProjectCreateRequest(
                project_id="p5",
                name="HeartbeatProject",
                project_path="/tmp/p5",
                unity_path="/Applications/Unity",
                tags=[],
            )
        )
        session = self.repo.create_session(
            client_id="client-hb",
            project_id="p5",
            status="starting",
            lease_expires_at=datetime.now(timezone.utc) + timedelta(minutes=5),
        )
        registered = self.repo.register_agent(
            session.session_id,
            "http://127.0.0.1:9900",
            {"tools": ["ping"]},
        )
        self.assertIsNotNone(registered)
        stale_heartbeat = (datetime.now(timezone.utc) - timedelta(seconds=120)).isoformat()
        with self.db.connect() as conn:
            conn.execute(
                "UPDATE sessions SET heartbeat_at = ? WHERE session_id = ?",
                (stale_heartbeat, session.session_id),
            )

        expired = self.repo.expire_stale_heartbeats(datetime.now(timezone.utc) - timedelta(seconds=30))
        self.assertEqual(expired, 1)

        dead = self.repo.get_session(session.session_id)
        self.assertEqual(dead.status, "dead")

    def test_multiple_live_sessions_allowed_for_same_client(self) -> None:
        self.repo.upsert_project(
            ProjectCreateRequest(
                project_id="p6",
                name="ProjectOne",
                project_path="/tmp/p6",
                unity_path="/Applications/Unity",
                tags=[],
            )
        )
        self.repo.upsert_project(
            ProjectCreateRequest(
                project_id="p7",
                name="ProjectTwo",
                project_path="/tmp/p7",
                unity_path="/Applications/Unity",
                tags=[],
            )
        )

        session_one = self.repo.create_session(
            client_id="client-multi",
            project_id="p6",
            status="starting",
            lease_expires_at=datetime.now(timezone.utc) + timedelta(minutes=5),
        )
        session_two = self.repo.create_session(
            client_id="client-multi",
            project_id="p7",
            status="starting",
            lease_expires_at=datetime.now(timezone.utc) + timedelta(minutes=5),
        )

        reloaded_one = self.repo.get_session(session_one.session_id)
        reloaded_two = self.repo.get_session(session_two.session_id)
        self.assertEqual(reloaded_one.status, "starting")
        self.assertEqual(reloaded_two.status, "starting")

    def test_list_sessions_filters_client_and_dead(self) -> None:
        self.repo.upsert_project(
            ProjectCreateRequest(
                project_id="p8",
                name="ClientA",
                project_path="/tmp/p8",
                unity_path="/Applications/Unity",
                tags=[],
            )
        )
        self.repo.upsert_project(
            ProjectCreateRequest(
                project_id="p9",
                name="ClientB",
                project_path="/tmp/p9",
                unity_path="/Applications/Unity",
                tags=[],
            )
        )

        alive = self.repo.create_session(
            client_id="client-a",
            project_id="p8",
            status="ready",
            lease_expires_at=datetime.now(timezone.utc) + timedelta(minutes=5),
        )
        dead = self.repo.create_session(
            client_id="client-b",
            project_id="p9",
            status="ready",
            lease_expires_at=datetime.now(timezone.utc) + timedelta(minutes=5),
        )
        self.repo.kill_session(dead.session_id)

        active_for_a = self.repo.list_sessions(client_id="client-a")
        self.assertEqual(len(active_for_a), 1)
        self.assertEqual(active_for_a[0].session_id, alive.session_id)

        active_all = self.repo.list_sessions()
        self.assertEqual(len(active_all), 1)
        self.assertEqual(active_all[0].session_id, alive.session_id)

        with_dead = self.repo.list_sessions(include_dead=True)
        self.assertEqual(len(with_dead), 2)

    def test_kill_session_clears_agent_credentials(self) -> None:
        self.repo.upsert_project(
            ProjectCreateRequest(
                project_id="p10",
                name="KillSessionProject",
                project_path="/tmp/p10",
                unity_path="/Applications/Unity",
                tags=[],
            )
        )
        session = self.repo.create_session(
            client_id="client-kill",
            project_id="p10",
            status="starting",
            lease_expires_at=datetime.now(timezone.utc) + timedelta(minutes=5),
        )
        registered = self.repo.register_agent(
            session.session_id,
            "http://127.0.0.1:9910",
            {"tools": ["ping"]},
        )
        self.assertIsNotNone(registered)
        self.assertIsNotNone(registered.agent_token)

        dead = self.repo.kill_session(session.session_id)
        self.assertIsNotNone(dead)
        self.assertEqual(dead.status, "dead")
        self.assertIsNone(dead.agent_token)
        self.assertIsNone(dead.agent_endpoint)

    def test_revive_expired_session_from_heartbeat(self) -> None:
        self.repo.upsert_project(
            ProjectCreateRequest(
                project_id="p11",
                name="ReviveSessionProject",
                project_path="/tmp/p11",
                unity_path="/Applications/Unity",
                tags=[],
            )
        )
        session = self.repo.create_session(
            client_id="client-revive",
            project_id="p11",
            status="starting",
            lease_expires_at=datetime.now(timezone.utc) + timedelta(seconds=1),
        )
        registered = self.repo.register_agent(
            session.session_id,
            "http://127.0.0.1:9920",
            {"tools": ["ping"]},
        )
        self.assertIsNotNone(registered)
        self.assertIsNotNone(registered.agent_token)

        self.repo.expire_old_sessions(datetime.now(timezone.utc) + timedelta(minutes=1))
        expired = self.repo.get_session(session.session_id)
        self.assertIsNotNone(expired)
        self.assertEqual(expired.status, "dead")
        self.assertFalse(self.repo.has_non_dead_session_for_project("p11"))

        revived = self.repo.revive_session_from_heartbeat(
            session.session_id,
            datetime.now(timezone.utc) + timedelta(minutes=5),
        )
        self.assertIsNotNone(revived)
        self.assertEqual(revived.status, "ready")
        self.assertIsNotNone(revived.heartbeat_at)
        self.assertTrue(self.repo.has_non_dead_session_for_project("p11"))
        self.assertFalse(
            self.repo.has_non_dead_session_for_project("p11", exclude_session_id=session.session_id)
        )

    def test_get_active_session_for_project_prefers_ready(self) -> None:
        self.repo.upsert_project(
            ProjectCreateRequest(
                project_id="p12",
                name="ActiveSessionProject",
                project_path="/tmp/p12",
                unity_path="/Applications/Unity",
                tags=[],
            )
        )
        starting = self.repo.create_session(
            client_id="client-active",
            project_id="p12",
            status="starting",
            lease_expires_at=datetime.now(timezone.utc) + timedelta(minutes=5),
        )
        ready = self.repo.create_session(
            client_id="client-active",
            project_id="p12",
            status="ready",
            lease_expires_at=datetime.now(timezone.utc) + timedelta(minutes=5),
        )

        active = self.repo.get_active_session_for_project("p12")
        self.assertIsNotNone(active)
        self.assertEqual(active.session_id, ready.session_id)

        self.repo.kill_session(ready.session_id)
        fallback = self.repo.get_active_session_for_project("p12")
        self.assertIsNotNone(fallback)
        self.assertEqual(fallback.session_id, starting.session_id)


if __name__ == "__main__":
    unittest.main()
