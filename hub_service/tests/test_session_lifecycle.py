from __future__ import annotations

import tempfile
import unittest
import signal
from dataclasses import replace
from datetime import datetime, timedelta, timezone
from pathlib import Path
from unittest.mock import patch

import app.main as hub_main
from fastapi import HTTPException
from app.db import Database
from app.models import ProjectCreateRequest, SelectProjectRequest
from app.repository import HubRepository


class SessionLifecycleTests(unittest.TestCase):
    def setUp(self) -> None:
        self.temp_dir = tempfile.TemporaryDirectory()
        db_path = Path(self.temp_dir.name) / "test.db"
        self.db = Database(db_path)
        self.db.init_schema()
        self.repo = HubRepository(self.db)
        self.repo.upsert_project(
            ProjectCreateRequest(
                project_id="p-session",
                name="Session Project",
                project_path="/tmp/p-session",
                unity_path="/Applications/Unity",
                tags=[],
            )
        )

        self.repo_patcher = patch("app.main.repo", self.repo)
        self.repo_patcher.start()

    def tearDown(self) -> None:
        self.repo_patcher.stop()
        self.temp_dir.cleanup()

    def test_select_project_reuses_existing_session_without_relaunch(self) -> None:
        existing = self.repo.create_session(
            client_id="client-a",
            project_id="p-session",
            status="starting",
            lease_expires_at=datetime.now(timezone.utc) + timedelta(minutes=5),
        )
        payload = SelectProjectRequest(
            client_id="client-a",
            project_id="p-session",
            auto_launch=True,
        )

        with patch("app.main.launch_unity") as launch_mock:
            response = hub_main.select_project(payload)

        self.assertFalse(response.launched)
        self.assertEqual(response.session.session_id, existing.session_id)
        launch_mock.assert_not_called()

    def test_select_project_blocks_duplicate_running_unity_instance(self) -> None:
        payload = SelectProjectRequest(
            client_id="client-dup",
            project_id="p-session",
            auto_launch=True,
        )

        with patch("app.main.find_running_unity_project_pid", return_value=7777), patch("app.main.launch_unity") as launch_mock:
            with self.assertRaises(HTTPException) as raised:
                hub_main.select_project(payload)

        self.assertEqual(raised.exception.status_code, 409)
        self.assertIn("already running", str(raised.exception.detail))
        launch_mock.assert_not_called()
        self.assertIsNone(self.repo.get_active_session_for_project("p-session"))

    def test_kill_session_skips_recent_starting_session_without_force(self) -> None:
        session = self.repo.create_session(
            client_id="client-b",
            project_id="p-session",
            status="starting",
            lease_expires_at=datetime.now(timezone.utc) + timedelta(minutes=5),
        )
        settings_override = replace(hub_main.settings, starting_session_grace_seconds=120)

        with patch("app.main.settings", settings_override):
            preserved = hub_main.kill_session(session.session_id)

        self.assertEqual(preserved.status, "starting")
        self.assertEqual(self.repo.get_session(session.session_id).status, "starting")

        with patch("app.main.settings", settings_override):
            killed = hub_main.kill_session(session.session_id, force=True)

        self.assertEqual(killed.status, "dead")

    def test_kill_session_allows_expired_starting_session_without_force(self) -> None:
        session = self.repo.create_session(
            client_id="client-c",
            project_id="p-session",
            status="starting",
            lease_expires_at=datetime.now(timezone.utc) + timedelta(minutes=5),
        )
        old_created = (datetime.now(timezone.utc) - timedelta(minutes=10)).isoformat()
        with self.db.connect() as conn:
            conn.execute(
                "UPDATE sessions SET created_at = ?, updated_at = ? WHERE session_id = ?",
                (old_created, old_created, session.session_id),
            )

        settings_override = replace(hub_main.settings, starting_session_grace_seconds=120)
        with patch("app.main.settings", settings_override):
            killed = hub_main.kill_session(session.session_id)

        self.assertEqual(killed.status, "dead")

    def test_kill_session_force_quit_terminates_unity_process(self) -> None:
        session = self.repo.create_session(
            client_id="client-force-quit",
            project_id="p-session",
            status="ready",
            lease_expires_at=datetime.now(timezone.utc) + timedelta(minutes=5),
        )
        self.repo.set_session_unity_pid(session.session_id, 8080)

        with patch("app.main.os.kill") as kill_mock:
            killed = hub_main.kill_session(session.session_id, force=True, terminate_process=True)

        self.assertEqual(killed.status, "dead")
        kill_mock.assert_called_once_with(8080, signal.SIGKILL)


if __name__ == "__main__":
    unittest.main()
