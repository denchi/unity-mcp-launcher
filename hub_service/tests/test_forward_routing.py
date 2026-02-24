from __future__ import annotations

import unittest
from datetime import datetime, timezone

from fastapi import HTTPException

from app.main import resolve_forward_base
from app.models import ForwardCallRequest, SessionRecord


def make_session(agent_endpoint: str | None, tool_manifest: dict | None = None) -> SessionRecord:
    now = datetime.now(timezone.utc)
    return SessionRecord(
        session_id="s1",
        client_id="c1",
        project_id="p1",
        status="ready",
        lease_expires_at=now,
        launch_token="launch",
        agent_token="agent",
        agent_endpoint=agent_endpoint,
        tool_manifest=tool_manifest or {},
        heartbeat_at=now,
        created_at=now,
        updated_at=now,
    )


class ForwardRoutingTests(unittest.TestCase):
    def test_explicit_bridge_target(self) -> None:
        session = make_session("http://127.0.0.1:7072", {"bridge_url": "http://127.0.0.1:7071"})
        payload = ForwardCallRequest(method="GET", path="/tools", target="bridge", json={})
        base, resolved = resolve_forward_base(session, payload)
        self.assertEqual(base, "http://127.0.0.1:7071")
        self.assertEqual(resolved, "bridge")

    def test_tools_path_falls_back_to_bridge(self) -> None:
        session = make_session("http://127.0.0.1:7072", {"bridge_url": "http://127.0.0.1:7071"})
        payload = ForwardCallRequest(method="GET", path="/tools", target="agent", json={})
        base, resolved = resolve_forward_base(session, payload)
        self.assertEqual(base, "http://127.0.0.1:7071")
        self.assertEqual(resolved, "bridge")

    def test_non_tools_path_uses_agent(self) -> None:
        session = make_session("http://127.0.0.1:7072", {"bridge_url": "http://127.0.0.1:7071"})
        payload = ForwardCallRequest(method="GET", path="/mcp/health", target="agent", json={})
        base, resolved = resolve_forward_base(session, payload)
        self.assertEqual(base, "http://127.0.0.1:7072")
        self.assertEqual(resolved, "agent")

    def test_bridge_target_requires_bridge_url(self) -> None:
        session = make_session("http://127.0.0.1:7072", {})
        payload = ForwardCallRequest(method="GET", path="/tools", target="bridge", json={})
        with self.assertRaises(HTTPException) as raised:
            resolve_forward_base(session, payload)
        self.assertEqual(raised.exception.status_code, 409)


if __name__ == "__main__":
    unittest.main()
