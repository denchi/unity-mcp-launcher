from __future__ import annotations

import json
import os
import socket
import subprocess
from pathlib import Path

from typing import Optional

from .models import ProjectRecord


class UnityLaunchError(Exception):
    pass


def warmup_unity_execute_method(executable: str, project_path: str, execute_method: str) -> None:
    args = [
        executable,
        "-batchmode",
        "-quit",
        "-nographics",
        "-projectPath",
        project_path,
        "-executeMethod",
        execute_method,
    ]
    try:
        result = subprocess.run(
            args,
            stdin=subprocess.DEVNULL,
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
            check=False,
            timeout=900,
        )
    except (OSError, subprocess.TimeoutExpired) as exc:
        raise UnityLaunchError(f"Failed to warm up Unity execute method before launch: {exc}") from exc

    if result.returncode != 0:
        raise UnityLaunchError(
            f"Unity execute-method warmup failed with exit code {result.returncode}. "
            "Open the project once in Unity and verify package initialization."
        )


def refresh_unity_packages(executable: str, project_path: str) -> None:
    args = [
        executable,
        "-batchmode",
        "-quit",
        "-nographics",
        "-projectPath",
        project_path,
    ]
    try:
        result = subprocess.run(
            args,
            stdin=subprocess.DEVNULL,
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
            check=False,
            timeout=300,
        )
    except (OSError, subprocess.TimeoutExpired) as exc:
        raise UnityLaunchError(f"Failed to refresh Unity packages before launch: {exc}") from exc

    if result.returncode != 0:
        raise UnityLaunchError(
            f"Unity package refresh failed with exit code {result.returncode}. "
            "Open the project once in Unity and verify package resolution."
        )


def ensure_unity_package_manifest_dependency(
    project_path: str,
    package_name: str,
    package_git_url: str,
) -> bool:
    normalized_name = package_name.strip()
    normalized_url = package_git_url.strip()

    if not normalized_name or not normalized_url:
        raise UnityLaunchError(
            "Unity package patch is misconfigured: package name and Git URL are both required."
        )

    manifest_path = Path(project_path) / "Packages" / "manifest.json"
    if not manifest_path.exists():
        raise UnityLaunchError(f"Unity manifest not found: {manifest_path}")

    try:
        raw = manifest_path.read_text(encoding="utf-8")
        manifest = json.loads(raw)
    except OSError as exc:
        raise UnityLaunchError(f"Failed reading Unity manifest: {exc}") from exc
    except json.JSONDecodeError as exc:
        raise UnityLaunchError(f"Unity manifest is not valid JSON: {manifest_path}") from exc

    dependencies = manifest.get("dependencies")
    if not isinstance(dependencies, dict):
        raise UnityLaunchError(f"Unity manifest has no valid dependencies object: {manifest_path}")

    existing = dependencies.get(normalized_name)
    if existing == normalized_url:
        return False

    dependencies[normalized_name] = normalized_url
    manifest["dependencies"] = dependencies

    serialized = json.dumps(manifest, indent=2) + "\n"
    tmp_path = manifest_path.with_suffix(".json.tmp")
    try:
        tmp_path.write_text(serialized, encoding="utf-8")
        tmp_path.replace(manifest_path)
    except OSError as exc:
        raise UnityLaunchError(f"Failed writing Unity manifest: {exc}") from exc

    return True


def allocate_loopback_url(path: str = "") -> str:
    with socket.socket(socket.AF_INET, socket.SOCK_STREAM) as sock:
        sock.bind(("127.0.0.1", 0))
        port = sock.getsockname()[1]
    normalized_path = ""
    if path:
        normalized_path = path if path.startswith("/") else f"/{path}"
    return f"http://127.0.0.1:{port}{normalized_path}"


def resolve_unity_executable(unity_path: str) -> str:
    path = Path(unity_path)
    if path.suffix == ".app":
        candidate = path / "Contents" / "MacOS" / "Unity"
        return str(candidate)
    return unity_path


def launch_unity(
    project: ProjectRecord,
    headless: bool,
    execute_method: Optional[str],
    env_overrides: Optional[dict[str, str]] = None,
    package_name: Optional[str] = None,
    package_git_url: Optional[str] = None,
) -> int:
    executable = resolve_unity_executable(project.unity_path)
    if not os.path.exists(executable):
        raise UnityLaunchError(f"Unity executable not found: {executable}")
    if not os.access(executable, os.X_OK):
        raise UnityLaunchError(f"Unity executable is not runnable: {executable}")

    normalized_name = (package_name or "").strip()
    normalized_url = (package_git_url or "").strip()
    normalized_execute_method = (execute_method or "").strip()
    manifest_changed = False
    if normalized_name or normalized_url:
        manifest_changed = ensure_unity_package_manifest_dependency(
            project_path=project.project_path,
            package_name=normalized_name,
            package_git_url=normalized_url,
        )
        if manifest_changed and normalized_execute_method:
            refresh_unity_packages(executable=executable, project_path=project.project_path)
            warmup_unity_execute_method(
                executable=executable,
                project_path=project.project_path,
                execute_method=normalized_execute_method,
            )

    args = [executable, "-projectPath", project.project_path]
    if headless:
        args.extend(["-batchmode", "-nographics"])
    if normalized_execute_method:
        args.extend(["-executeMethod", normalized_execute_method])

    env = os.environ.copy()
    if env_overrides:
        env.update(env_overrides)
    try:
        process = subprocess.Popen(
            args,
            stdin=subprocess.DEVNULL,
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
            env=env,
        )
    except OSError as exc:
        raise UnityLaunchError(f"Failed to launch Unity: {exc}") from exc
    return process.pid
