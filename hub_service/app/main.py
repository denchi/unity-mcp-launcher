from __future__ import annotations

import logging
from datetime import datetime, timedelta, timezone
from pathlib import Path
from typing import Optional

import httpx
from fastapi import Depends, FastAPI, Header, HTTPException, status

from .config import settings
from .db import Database
from .launcher import UnityLaunchError, allocate_loopback_url, launch_unity
from .models import (
    ForwardCallRequest,
    ForwardCallResponse,
    HealthResponse,
    HeartbeatRequest,
    LaunchProjectRequest,
    ProjectCreateRequest,
    ProjectRecord,
    RegisterAgentRequest,
    RegisterAgentResponse,
    SelectProjectRequest,
    SelectProjectResponse,
    SessionRecord,
    UnityInstallationRecord,
    UnityInstallRequest,
    UnityLocalInstallRequest,
    UnityUninstallRequest,
    UnityVersionResponse,
)
from .project_version import detect_project_unity_version
from .repository import HubRepository
from .unity_registry import (
    UnityRegistryError,
    find_unity_installation_by_version,
    list_unity_installations,
    register_custom_unity_installation,
    install_unity_version,
    remove_unity_installation,
    remove_custom_installation_by_path,
)

app = FastAPI(title="Unity MCP Hub", version="0.1.0")
db = Database(settings.database_path)
repo = HubRepository(db)
logger = logging.getLogger("uvicorn.error")


@app.on_event("startup")
def startup() -> None:
    db.init_schema()


def require_auth(x_hub_token: Optional[str] = Header(default=None)) -> None:
    if x_hub_token != settings.auth_token:
        raise HTTPException(status_code=status.HTTP_401_UNAUTHORIZED, detail="invalid hub token")


def session_lease_expiry() -> datetime:
    return datetime.now(timezone.utc) + timedelta(seconds=settings.session_ttl_seconds)


def agent_hub_url() -> str:
    if settings.agent_hub_url.strip():
        return settings.agent_hub_url.strip().rstrip("/")
    return f"http://127.0.0.1:{settings.port}"


def resolve_execute_method(candidate: Optional[str]) -> Optional[str]:
    if candidate and candidate.strip():
        return candidate.strip()
    if settings.default_execute_method.strip():
        return settings.default_execute_method.strip()
    return None


def launch_env_for_session(session: SessionRecord, runtime_server_url: str) -> dict[str, str]:
    return {
        "UNITY_MCP_MODE": "hub",
        "UNITY_MCP_HUB_URL": agent_hub_url(),
        "UNITY_MCP_HUB_TOKEN": settings.auth_token,
        "UNITY_MCP_SESSION_ID": session.session_id,
        "UNITY_MCP_LAUNCH_TOKEN": session.launch_token,
        "UNITY_MCP_SERVER_URL": runtime_server_url,
        "UNITY_MCP_HEARTBEAT_SECONDS": str(settings.agent_heartbeat_seconds),
    }


def resolve_agent_health_url(session: SessionRecord) -> Optional[str]:
    if isinstance(session.tool_manifest, dict):
        health_url = session.tool_manifest.get("health_url")
        if isinstance(health_url, str) and health_url.strip():
            return health_url.strip()
    if session.agent_endpoint:
        return f"{session.agent_endpoint.rstrip('/')}/mcp/health"
    return None


def session_looks_alive(session: SessionRecord) -> bool:
    health_url = resolve_agent_health_url(session)
    if not health_url:
        return False
    try:
        with httpx.Client(timeout=1.5) as client:
            response = client.get(health_url)
            return 200 <= response.status_code < 300
    except httpx.HTTPError:
        return False


def run_maintenance() -> None:
    now = datetime.now(timezone.utc)
    repo.expire_old_sessions(now)
    if settings.heartbeat_timeout_seconds > 0:
        stale_before = now - timedelta(seconds=settings.heartbeat_timeout_seconds)
        stale_sessions = repo.list_stale_ready_sessions(stale_before)
        for session in stale_sessions:
            if session_looks_alive(session):
                repo.touch_heartbeat(session.session_id)
                repo.extend_lease(session.session_id, session_lease_expiry())
            else:
                repo.kill_session(session.session_id)


def get_live_session(session_id: str) -> SessionRecord:
    run_maintenance()
    session = repo.get_session(session_id)
    if not session:
        raise HTTPException(status_code=404, detail="session not found")
    if session.status == "dead":
        raise HTTPException(status_code=409, detail="session is dead")
    if session.lease_expires_at < datetime.now(timezone.utc):
        repo.kill_session(session_id)
        raise HTTPException(status_code=409, detail="session expired")
    return session


def resolve_forward_base(session: SessionRecord, payload: ForwardCallRequest) -> tuple[str, str]:
    bridge_url = None
    if isinstance(session.tool_manifest, dict):
        bridge_url = session.tool_manifest.get("bridge_url")

    if payload.target == "bridge":
        if not bridge_url:
            raise HTTPException(status_code=409, detail="bridge endpoint unavailable")
        return str(bridge_url), "bridge"

    if payload.path.startswith("/tools") and bridge_url:
        return str(bridge_url), "bridge"

    if not session.agent_endpoint:
        raise HTTPException(status_code=409, detail="agent endpoint unavailable")
    return session.agent_endpoint, "agent"


def list_unity_installation_records() -> list[UnityInstallationRecord]:
    installations = list_unity_installations(
        settings.unity_install_root,
        settings.unity_custom_installations_path,
        settings.unity_hidden_installations_path,
    )
    return [installation_to_record(entry) for entry in installations]


def installation_display_path(install_path: Path) -> Path:
    unity_app = install_path / "Unity.app"
    if unity_app.exists() and unity_app.is_dir():
        return unity_app
    return install_path


def installation_to_record(installation) -> UnityInstallationRecord:
    return UnityInstallationRecord(
        version=installation.version,
        install_path=str(installation_display_path(installation.install_path)),
        unity_executable=str(installation.unity_executable),
        source=installation.source,
    )


def resolve_project_for_launch(project: ProjectRecord, unity_version: Optional[str]) -> ProjectRecord:
    if not unity_version:
        return project

    installation = find_unity_installation_by_version(
        unity_version,
        settings.unity_install_root,
        settings.unity_custom_installations_path,
        settings.unity_hidden_installations_path,
    )
    if not installation:
        raise HTTPException(
            status_code=status.HTTP_404_NOT_FOUND,
            detail=f"Unity version {unity_version} is not installed.",
        )

    return project.copy(update={"unity_path": str(installation.unity_executable)})


def is_within_starting_grace(session: SessionRecord, now: Optional[datetime] = None) -> bool:
    if session.status != "starting":
        return False
    if settings.starting_session_grace_seconds <= 0:
        return False
    reference = now or datetime.now(timezone.utc)
    age_seconds = (reference - session.created_at).total_seconds()
    return age_seconds < settings.starting_session_grace_seconds


@app.get("/health", response_model=HealthResponse)
def health() -> HealthResponse:
    return HealthResponse(status="ok", now=datetime.now(timezone.utc))


@app.post("/projects", response_model=ProjectRecord, dependencies=[Depends(require_auth)])
def upsert_project(payload: ProjectCreateRequest) -> ProjectRecord:
    return repo.upsert_project(payload)


@app.get("/projects", response_model=list[ProjectRecord], dependencies=[Depends(require_auth)])
def list_projects() -> list[ProjectRecord]:
    run_maintenance()
    return repo.list_projects()


@app.delete("/projects/{project_id}", dependencies=[Depends(require_auth)])
def delete_project(project_id: str) -> dict:
    deleted = repo.delete_project(project_id)
    if not deleted:
        raise HTTPException(status_code=404, detail="project not found")
    return {"ok": True}


@app.get("/projects/{project_id}/unity-version", response_model=UnityVersionResponse, dependencies=[Depends(require_auth)])
def project_unity_version(project_id: str) -> UnityVersionResponse:
    project = repo.get_project(project_id)
    if not project:
        raise HTTPException(status_code=404, detail="project not found")

    detected = detect_project_unity_version(project.project_path)
    return UnityVersionResponse(unity_version=detected)


@app.get("/unity/installations", response_model=list[UnityInstallationRecord], dependencies=[Depends(require_auth)])
def unity_installations() -> list[UnityInstallationRecord]:
    return list_unity_installation_records()


@app.post("/unity/installations", dependencies=[Depends(require_auth)])
def install_unity(payload: UnityInstallRequest) -> dict:
    try:
        install_unity_version(payload.version, settings.unity_hub_cli_path)
    except UnityRegistryError as exc:
        raise HTTPException(status_code=500, detail=str(exc)) from exc
    return {"ok": True}


@app.post("/unity/installations/local", response_model=UnityInstallationRecord, dependencies=[Depends(require_auth)])
def register_local_installation(payload: UnityLocalInstallRequest) -> UnityInstallationRecord:
    try:
        installation = register_custom_unity_installation(
            Path(payload.install_path),
            settings.unity_install_root,
            settings.unity_custom_installations_path,
            settings.unity_hidden_installations_path,
        )
    except UnityRegistryError as exc:
        raise HTTPException(status_code=500, detail=str(exc)) from exc

    return installation_to_record(installation)


@app.delete("/unity/installations/{version}", dependencies=[Depends(require_auth)])
def uninstall_unity(version: str, source: Optional[str] = None) -> dict:
    try:
        remove_unity_installation(
            version,
            settings.unity_install_root,
            settings.unity_custom_installations_path,
            settings.unity_hidden_installations_path,
            preferred_source=source,
        )
    except UnityRegistryError as exc:
        raise HTTPException(status_code=500, detail=str(exc)) from exc
    return {"ok": True}


@app.delete("/unity/installations/local", dependencies=[Depends(require_auth)])
def forget_local_installation(payload: UnityLocalInstallRequest) -> dict:
    try:
        remove_custom_installation_by_path(
            Path(payload.install_path),
            settings.unity_custom_installations_path,
        )
    except UnityRegistryError as exc:
        raise HTTPException(status_code=500, detail=str(exc)) from exc
    return {"ok": True}


@app.post("/projects/launch", dependencies=[Depends(require_auth)])
def launch_project(payload: LaunchProjectRequest) -> dict:
    project = repo.get_project(payload.project_id)
    if not project:
        raise HTTPException(status_code=404, detail="project not found")
    try:
        prepared = resolve_project_for_launch(project, payload.unity_version)
        pid = launch_unity(
            prepared,
            payload.headless,
            resolve_execute_method(payload.execute_method),
            package_name=settings.unity_agent_package_name,
            package_git_url=settings.unity_agent_package_git_url,
        )
    except UnityLaunchError as exc:
        raise HTTPException(status_code=400, detail=str(exc)) from exc
    repo.mark_project_status(project.project_id, "starting")
    return {"ok": True, "pid": pid}


@app.post("/sessions/select", response_model=SelectProjectResponse, dependencies=[Depends(require_auth)])
def select_project(payload: SelectProjectRequest) -> SelectProjectResponse:
    run_maintenance()
    project = repo.find_project(payload.project_id, payload.name, payload.tags, payload.most_recent)
    if not project:
        raise HTTPException(status_code=404, detail="no project matches selection")

    active = repo.get_active_session_for_project(project.project_id)
    if active:
        reused = repo.extend_lease(active.session_id, session_lease_expiry()) or active
        return SelectProjectResponse(session=reused, launched=False)

    # Launch requests from the app should start Unity explicitly; persisted project status
    # can be stale after crashes/restarts, so do not gate launch on "ready".
    launched = payload.auto_launch
    session = repo.create_session(
        client_id=payload.client_id,
        project_id=project.project_id,
        status="starting" if launched else "ready",
        lease_expires_at=session_lease_expiry(),
    )

    if launched:
        try:
            runtime_server_url = allocate_loopback_url("/mcp")
            logger.info(
                "launch session=%s project=%s mode=hub runtime_server_url=%s",
                session.session_id,
                project.project_id,
                runtime_server_url,
            )
            launch_unity(
                resolve_project_for_launch(project, payload.unity_version),
                payload.launch_headless,
                resolve_execute_method(payload.execute_method),
                env_overrides=launch_env_for_session(session, runtime_server_url),
                package_name=settings.unity_agent_package_name,
                package_git_url=settings.unity_agent_package_git_url,
            )
        except UnityLaunchError as exc:
            repo.kill_session(session.session_id)
            raise HTTPException(status_code=400, detail=str(exc)) from exc

    return SelectProjectResponse(session=session, launched=launched)


@app.get("/sessions/{session_id}", response_model=SessionRecord, dependencies=[Depends(require_auth)])
def get_session(session_id: str) -> SessionRecord:
    run_maintenance()
    session = repo.get_session(session_id)
    if not session:
        raise HTTPException(status_code=404, detail="session not found")
    return session


@app.get("/sessions", response_model=list[SessionRecord], dependencies=[Depends(require_auth)])
def list_sessions(client_id: Optional[str] = None, include_dead: bool = False) -> list[SessionRecord]:
    run_maintenance()
    return repo.list_sessions(client_id=client_id, include_dead=include_dead)


@app.post("/sessions/{session_id}/renew", response_model=SessionRecord, dependencies=[Depends(require_auth)])
def renew_session(session_id: str) -> SessionRecord:
    session = get_live_session(session_id)
    updated = repo.extend_lease(session.session_id, session_lease_expiry())
    if not updated:
        raise HTTPException(status_code=404, detail="session not found")
    return updated


@app.post("/sessions/{session_id}/kill", response_model=SessionRecord, dependencies=[Depends(require_auth)])
def kill_session(session_id: str, force: bool = False) -> SessionRecord:
    current = repo.get_session(session_id)
    if not current:
        raise HTTPException(status_code=404, detail="session not found")
    if not force and is_within_starting_grace(current):
        return current

    session = repo.kill_session(session_id)
    if not session:
        raise HTTPException(status_code=404, detail="session not found")
    return session


@app.post("/agents/register", response_model=RegisterAgentResponse, dependencies=[Depends(require_auth)])
def register_agent(payload: RegisterAgentRequest) -> RegisterAgentResponse:
    session = repo.get_session(payload.session_id)
    if not session:
        raise HTTPException(status_code=404, detail="session not found")
    if session.launch_token != payload.launch_token:
        raise HTTPException(status_code=401, detail="invalid launch token")
    if session.status == "dead":
        raise HTTPException(status_code=409, detail="session is dead")

    updated = repo.register_agent(payload.session_id, payload.endpoint, payload.tool_manifest)
    if not updated or not updated.agent_token:
        raise HTTPException(status_code=500, detail="could not register agent")

    return RegisterAgentResponse(accepted=True, agent_token=updated.agent_token)


@app.post("/agents/heartbeat", dependencies=[Depends(require_auth)])
def heartbeat(payload: HeartbeatRequest) -> dict:
    run_maintenance()
    session = repo.get_session(payload.session_id)
    if not session:
        raise HTTPException(status_code=404, detail="session not found")
    if session.agent_token != payload.agent_token:
        raise HTTPException(status_code=401, detail="invalid agent token")

    if session.status == "dead":
        if repo.has_non_dead_session_for_project(session.project_id, exclude_session_id=session.session_id):
            raise HTTPException(status_code=409, detail="session is dead")

        revived = repo.revive_session_from_heartbeat(payload.session_id, session_lease_expiry())
        if not revived:
            raise HTTPException(status_code=404, detail="session not found")
        return {"ok": True, "resumed": True}

    if session.lease_expires_at < datetime.now(timezone.utc):
        repo.kill_session(payload.session_id)
        raise HTTPException(status_code=409, detail="session expired")

    repo.touch_heartbeat(payload.session_id)
    repo.extend_lease(payload.session_id, session_lease_expiry())
    return {"ok": True, "resumed": False}


@app.post("/sessions/{session_id}/forward", response_model=ForwardCallResponse, dependencies=[Depends(require_auth)])
async def forward_call(session_id: str, payload: ForwardCallRequest) -> ForwardCallResponse:
    session = get_live_session(session_id)
    if session.status != "ready":
        raise HTTPException(status_code=409, detail="agent not ready")

    base_url, resolved_target = resolve_forward_base(session, payload)

    path = payload.path if payload.path.startswith("/") else f"/{payload.path}"
    url = f"{base_url.rstrip('/')}{path}"
    headers = {"X-Hub-Session": session.session_id}
    if resolved_target == "agent" and session.agent_token:
        headers["X-Agent-Token"] = session.agent_token

    logger.info(
        "forward session=%s target=%s resolved_target=%s path=%s url=%s",
        session.session_id,
        payload.target,
        resolved_target,
        path,
        url,
    )

    try:
        async with httpx.AsyncClient(timeout=payload.timeout_seconds) as client:
            response = await client.request(
                payload.method,
                url,
                json=payload.body,
                headers=headers,
            )
    except httpx.HTTPError as exc:
        raise HTTPException(status_code=502, detail=f"agent request failed: {exc}") from exc

    try:
        body = response.json()
    except ValueError:
        body = response.text

    return ForwardCallResponse(status_code=response.status_code, body=body)


@app.post("/maintenance/expire", dependencies=[Depends(require_auth)])
def expire_sessions() -> dict:
    expired = repo.expire_old_sessions(datetime.now(timezone.utc))
    return {"expired": expired}
