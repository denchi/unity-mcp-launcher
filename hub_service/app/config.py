from __future__ import annotations

import os
import secrets
from dataclasses import dataclass
from pathlib import Path


def _default_auth_token_file() -> Path:
    explicit = os.getenv("HUB_AUTH_TOKEN_FILE", "").strip()
    if explicit:
        return Path(explicit).expanduser()
    return Path.home() / ".unity-mcp-hub" / "auth_token"


def _load_or_create_auth_token() -> str:
    explicit = os.getenv("HUB_AUTH_TOKEN", "").strip()
    if explicit:
        return explicit

    token_file = _default_auth_token_file()
    try:
        if token_file.exists():
            existing = token_file.read_text(encoding="utf-8").strip()
            if existing:
                return existing
    except OSError:
        pass

    generated = secrets.token_urlsafe(32)
    try:
        token_file.parent.mkdir(parents=True, exist_ok=True)
        fd = os.open(token_file, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
        with os.fdopen(fd, "w", encoding="utf-8") as handle:
            handle.write(generated + "\n")
    except OSError:
        # Fallback to in-memory token if file storage is unavailable.
        return generated
    return generated


@dataclass(frozen=True)
class Settings:
    host: str = os.getenv("HUB_HOST", "127.0.0.1")
    port: int = int(os.getenv("HUB_PORT", "8787"))
    database_path: Path = Path(os.getenv("HUB_DB_PATH", "./hub_service/hub.db"))
    auth_token_file: Path = _default_auth_token_file()
    auth_token: str = _load_or_create_auth_token()
    session_ttl_seconds: int = int(os.getenv("HUB_SESSION_TTL_SECONDS", "900"))
    heartbeat_timeout_seconds: int = int(os.getenv("HUB_HEARTBEAT_TIMEOUT_SECONDS", "30"))
    agent_hub_url: str = os.getenv("HUB_AGENT_HUB_URL", "")
    default_execute_method: str = os.getenv("HUB_DEFAULT_EXECUTE_METHOD", "")
    agent_heartbeat_seconds: int = int(os.getenv("HUB_AGENT_HEARTBEAT_SECONDS", "10"))
    unity_agent_package_name: str = os.getenv(
        "HUB_UNITY_AGENT_PACKAGE_NAME",
        "com.deathbygravitystudio.gptactions",
    ).strip()
    unity_agent_package_git_url: str = os.getenv(
        "HUB_UNITY_AGENT_PACKAGE_GIT_URL",
        "https://github.com/denchi/UnityGPTActions.git#feature/mcp",
    ).strip()
    unity_install_root: Path = Path(os.getenv("UNITY_INSTALL_ROOT", "/Applications/Unity/Hub/Editor"))
    unity_hub_cli_path: Path = Path(
        os.getenv("UNITY_HUB_CLI_PATH", "/Applications/Unity Hub/Unity Hub.app/Contents/MacOS/Unity Hub")
    )
    unity_custom_installations_path: Path = Path(
        os.getenv("UNITY_CUSTOM_INSTALLATIONS_PATH", "./hub_service/unity_installations.json")
    )
    unity_hidden_installations_path: Path = Path(
        os.getenv("UNITY_HIDDEN_INSTALLATIONS_PATH", "./hub_service/unity_hidden_installations.json")
    )
    starting_session_grace_seconds: int = int(os.getenv("HUB_STARTING_SESSION_GRACE_SECONDS", "120"))


settings = Settings()
