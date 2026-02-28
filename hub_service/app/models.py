from __future__ import annotations

from datetime import datetime
from typing import Any, Literal, Optional

from pydantic import BaseModel, Field


class ProjectCreateRequest(BaseModel):
    project_id: str = Field(min_length=1)
    name: str = Field(min_length=1)
    project_path: str = Field(min_length=1)
    unity_path: str = Field(min_length=1)
    tags: list[str] = Field(default_factory=list)


class ProjectRecord(BaseModel):
    project_id: str
    name: str
    project_path: str
    unity_path: str
    tags: list[str] = Field(default_factory=list)
    status: Literal["idle", "starting", "ready", "dead"]
    last_seen_at: Optional[datetime] = None
    created_at: datetime
    updated_at: datetime


class SelectProjectRequest(BaseModel):
    client_id: str = Field(min_length=1)
    project_id: Optional[str] = None
    name: Optional[str] = None
    tags: list[str] = Field(default_factory=list)
    most_recent: bool = False
    auto_launch: bool = True
    launch_headless: bool = False
    execute_method: Optional[str] = None
    unity_version: Optional[str] = None


class SessionRecord(BaseModel):
    session_id: str
    client_id: str
    project_id: str
    status: Literal["starting", "ready", "dead"]
    lease_expires_at: datetime
    launch_token: str
    agent_token: Optional[str] = None
    agent_endpoint: Optional[str] = None
    tool_manifest: dict[str, Any] = Field(default_factory=dict)
    heartbeat_at: Optional[datetime] = None
    created_at: datetime
    updated_at: datetime


class SelectProjectResponse(BaseModel):
    session: SessionRecord
    launched: bool


class RegisterAgentRequest(BaseModel):
    session_id: str
    launch_token: str
    endpoint: str = Field(min_length=1)
    tool_manifest: dict[str, Any] = Field(default_factory=dict)


class RegisterAgentResponse(BaseModel):
    accepted: bool
    agent_token: str


class HeartbeatRequest(BaseModel):
    session_id: str
    agent_token: str


class LaunchProjectRequest(BaseModel):
    project_id: str = Field(min_length=1)
    headless: bool = False
    execute_method: Optional[str] = None
    unity_version: Optional[str] = None


class ForwardCallRequest(BaseModel):
    method: Literal["GET", "POST", "PUT", "PATCH", "DELETE"] = "POST"
    path: str = "/mcp"
    target: Literal["agent", "bridge"] = "agent"
    body: dict[str, Any] = Field(default_factory=dict, alias="json")
    timeout_seconds: float = 30.0


class ForwardCallResponse(BaseModel):
    status_code: int
    body: Any


class HealthResponse(BaseModel):
    status: Literal["ok"]
    now: datetime


class UnityInstallationRecord(BaseModel):
    version: str
    install_path: str
    unity_executable: str
    source: str


class UnityInstallRequest(BaseModel):
    version: str = Field(min_length=1)


class UnityUninstallRequest(BaseModel):
    version: str = Field(min_length=1)


class UnityLocalInstallRequest(BaseModel):
    install_path: str = Field(min_length=1)


class UnityVersionResponse(BaseModel):
    unity_version: Optional[str] = None
