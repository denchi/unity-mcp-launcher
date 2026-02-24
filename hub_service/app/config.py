from __future__ import annotations

import os
from dataclasses import dataclass
from pathlib import Path


@dataclass(frozen=True)
class Settings:
    host: str = os.getenv("HUB_HOST", "127.0.0.1")
    port: int = int(os.getenv("HUB_PORT", "8787"))
    database_path: Path = Path(os.getenv("HUB_DB_PATH", "./hub_service/hub.db"))
    auth_token: str = os.getenv("HUB_AUTH_TOKEN", "dev-shared-secret")
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


settings = Settings()
