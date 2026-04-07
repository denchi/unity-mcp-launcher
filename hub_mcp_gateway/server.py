from __future__ import annotations

import os
import re
import socket
from dataclasses import dataclass
from pathlib import Path
from typing import Any, Literal, Optional
from urllib.parse import quote

import httpx
from mcp.server.fastmcp import FastMCP


def _slugify(value: str) -> str:
    lowered = value.strip().lower()
    normalized = re.sub(r"[^a-z0-9]+", "-", lowered)
    return normalized.strip("-") or "unity-hub-client"


def _default_client_id() -> str:
    return _slugify(socket.gethostname())


def _default_auth_token_file() -> Path:
    explicit = os.getenv("HUB_AUTH_TOKEN_FILE", "").strip()
    if explicit:
        return Path(explicit).expanduser()
    return Path.home() / ".unity-mcp-hub" / "auth_token"


def _default_hub_token() -> str:
    explicit = os.getenv("HUB_MCP_HUB_TOKEN", "").strip()
    if explicit:
        return explicit
    token_file = _default_auth_token_file()
    try:
        return token_file.read_text(encoding="utf-8").strip()
    except OSError:
        return ""


HUB_URL = os.getenv("HUB_MCP_HUB_URL", "http://127.0.0.1:8787").strip().rstrip("/")
HUB_TOKEN = _default_hub_token()
HUB_CLIENT_ID = os.getenv("HUB_MCP_CLIENT_ID", _default_client_id()).strip()
HUB_TIMEOUT_SECONDS = float(os.getenv("HUB_MCP_TIMEOUT_SECONDS", "20"))
HUB_DEFAULT_EXECUTE_METHOD = os.getenv("HUB_MCP_DEFAULT_EXECUTE_METHOD", "").strip()


@dataclass
class GatewayState:
    active_session_id: Optional[str] = None
    active_project_id: Optional[str] = None


state = GatewayState()
mcp = FastMCP("unity-mcp-hub-gateway")


def _health_request() -> dict[str, Any]:
    url = f"{HUB_URL}/health"
    with httpx.Client(timeout=HUB_TIMEOUT_SECONDS) as client:
        response = client.get(url)
    response.raise_for_status()
    return response.json()


def _hub_request(method: str, path: str, payload: Optional[dict[str, Any]] = None) -> dict[str, Any]:
    if not HUB_TOKEN:
        raise RuntimeError(
            "Hub token is not configured. Set HUB_MCP_HUB_TOKEN or ensure HUB_AUTH_TOKEN_FILE points to a valid token file."
        )
    url = f"{HUB_URL}{path}"
    headers = {"X-Hub-Token": HUB_TOKEN}

    try:
        with httpx.Client(timeout=HUB_TIMEOUT_SECONDS) as client:
            response = client.request(method=method, url=url, headers=headers, json=payload)
    except httpx.HTTPError as exc:
        raise RuntimeError(f"Hub request failed: {exc}") from exc

    if response.status_code >= 400:
        try:
            message = response.json().get("detail", response.text)
        except ValueError:
            message = response.text
        raise RuntimeError(f"Hub request failed ({response.status_code}): {message}")

    if not response.content:
        return {}
    try:
        return response.json()
    except ValueError as exc:
        raise RuntimeError("Hub response was not valid JSON") from exc


def _resolve_session_id(session_id: Optional[str]) -> str:
    candidate = (session_id or state.active_session_id or "").strip()
    if not candidate:
        raise RuntimeError("No active session. Call select_project first or pass session_id explicitly.")
    return candidate


def _forward_bridge(session_id: str, method: str, path: str, body: Optional[dict[str, Any]] = None) -> dict[str, Any]:
    payload = {
        "method": method,
        "path": path,
        "target": "bridge",
        "json": body or {},
    }
    return _hub_request("POST", f"/sessions/{session_id}/forward", payload)


@mcp.tool()
def hub_health() -> dict[str, Any]:
    """Check whether the Hub API is reachable."""
    return _health_request()


@mcp.tool()
def list_projects() -> list[dict[str, Any]]:
    """List projects registered in the Hub."""
    projects = _hub_request("GET", "/projects")
    if not isinstance(projects, list):
        return []
    return projects


@mcp.tool()
def list_sessions(include_dead: bool = False) -> list[dict[str, Any]]:
    """List sessions for this MCP client_id in the Hub."""
    query = "true" if include_dead else "false"
    encoded_client_id = quote(HUB_CLIENT_ID, safe="")
    sessions = _hub_request("GET", f"/sessions?client_id={encoded_client_id}&include_dead={query}")
    if not isinstance(sessions, list):
        return []
    return sessions


@mcp.tool()
def select_project(
    project_id: str = "",
    name: str = "",
    tags: Optional[list[str]] = None,
    most_recent: bool = False,
    auto_launch: bool = True,
    attach_if_running: bool = True,
    launch_headless: bool = False,
    execute_method: str = "",
) -> dict[str, Any]:
    """
    Select a project session in the Hub.

    This sets the active session for later Unity tool calls.
    """
    resolved_execute_method = execute_method.strip() or HUB_DEFAULT_EXECUTE_METHOD or None
    payload: dict[str, Any] = {
        "client_id": HUB_CLIENT_ID,
        "project_id": project_id.strip() or None,
        "name": name.strip() or None,
        "tags": tags or [],
        "most_recent": most_recent,
        "auto_launch": auto_launch,
        "attach_if_running": attach_if_running,
        "launch_headless": launch_headless,
        "execute_method": resolved_execute_method,
    }

    response = _hub_request("POST", "/sessions/select", payload)
    session = response.get("session", {})
    session_id = session.get("session_id")
    project_ref = session.get("project_id")
    if isinstance(session_id, str) and session_id:
        state.active_session_id = session_id
    if isinstance(project_ref, str) and project_ref:
        state.active_project_id = project_ref

    return {
        "client_id": HUB_CLIENT_ID,
        "active_session_id": state.active_session_id,
        "active_project_id": state.active_project_id,
        "launched": bool(response.get("launched", False)),
        "session": session,
    }


@mcp.tool()
def use_session(session_id: str) -> dict[str, Any]:
    """Set an existing session as active for subsequent Unity tool calls."""
    sid = session_id.strip()
    if not sid:
        raise RuntimeError("session_id is required")

    session = _hub_request("GET", f"/sessions/{sid}")
    state.active_session_id = sid
    state.active_project_id = session.get("project_id")
    return {
        "active_session_id": state.active_session_id,
        "active_project_id": state.active_project_id,
        "session": session,
    }


@mcp.tool()
def current_session() -> dict[str, Any]:
    """Get the currently active session and metadata."""
    if not state.active_session_id:
        return {"active_session_id": None, "active_project_id": None, "session": None}
    session = _hub_request("GET", f"/sessions/{state.active_session_id}")
    return {
        "active_session_id": state.active_session_id,
        "active_project_id": state.active_project_id,
        "session": session,
    }


@mcp.tool()
def clear_session() -> dict[str, Any]:
    """Clear local active-session context in this MCP gateway."""
    state.active_session_id = None
    state.active_project_id = None
    return {"ok": True}


@mcp.tool()
def kill_session(session_id: str = "", force: bool = False) -> dict[str, Any]:
    """Kill a Hub session and clear local active context if it matches."""
    sid = _resolve_session_id(session_id.strip() or None)
    force_flag = "true" if force else "false"
    session = _hub_request("POST", f"/sessions/{sid}/kill?force={force_flag}")
    session_status = str(session.get("status", "")).strip().lower()
    if sid == state.active_session_id and session_status == "dead":
        state.active_session_id = None
        state.active_project_id = None
    return {"killed_session": session, "active_session_id": state.active_session_id}


@mcp.tool()
def focus_unity_window(session_id: str = "") -> dict[str, Any]:
    """
    Bring the Unity Editor window for a session to the foreground.

    If session_id is omitted, uses the current active session.
    """
    sid = _resolve_session_id(session_id.strip() or None)
    response = _hub_request("POST", f"/sessions/{sid}/focus")
    return {
        "session_id": sid,
        "focused": bool(response.get("ok", False)),
        "unity_pid": response.get("unity_pid"),
    }


@mcp.tool()
def list_unity_tools(session_id: str = "") -> dict[str, Any]:
    """
    List Unity tools from the selected project's bridge endpoint.

    If session_id is omitted, uses the current active session.
    """
    sid = _resolve_session_id(session_id.strip() or None)
    forwarded = _forward_bridge(sid, "GET", "/tools")
    return {
        "session_id": sid,
        "forward_status_code": forwarded.get("status_code"),
        "tools": forwarded.get("body"),
    }


@mcp.tool()
def call_unity_tool(
    tool_name: str,
    arguments: Optional[dict[str, Any]] = None,
    session_id: str = "",
) -> dict[str, Any]:
    """
    Call a Unity bridge tool in the selected project's session.

    If session_id is omitted, uses the current active session.
    """
    name = tool_name.strip()
    if not name:
        raise RuntimeError("tool_name is required")

    sid = _resolve_session_id(session_id.strip() or None)
    forwarded = _forward_bridge(
        sid,
        "POST",
        "/tools/call",
        {"name": name, "arguments": arguments or {}},
    )
    return {
        "session_id": sid,
        "tool_name": name,
        "forward_status_code": forwarded.get("status_code"),
        "result": forwarded.get("body"),
    }


@mcp.tool()
def forward_unity_http(
    path: str,
    method: Literal["GET", "POST", "PUT", "PATCH", "DELETE"] = "POST",
    target: Literal["agent", "bridge"] = "agent",
    body: Optional[dict[str, Any]] = None,
    session_id: str = "",
) -> dict[str, Any]:
    """
    Forward an arbitrary HTTP call to the active Unity agent/bridge endpoint.
    Useful for low-level debugging.
    """
    raw_path = path.strip()
    if not raw_path:
        raise RuntimeError("path is required")
    sid = _resolve_session_id(session_id.strip() or None)
    payload = {
        "method": method,
        "path": raw_path if raw_path.startswith("/") else f"/{raw_path}",
        "target": target,
        "json": body or {},
    }
    forwarded = _hub_request("POST", f"/sessions/{sid}/forward", payload)
    return {
        "session_id": sid,
        "target": target,
        "path": payload["path"],
        "forward_status_code": forwarded.get("status_code"),
        "result": forwarded.get("body"),
    }
