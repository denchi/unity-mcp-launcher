from __future__ import annotations

import json
import os
import plistlib
import re
import subprocess
from dataclasses import dataclass
from pathlib import Path
from typing import Iterable, List, Optional


class UnityRegistryError(Exception):
    pass


@dataclass(frozen=True)
class UnityInstallation:
    version: str
    install_path: Path
    unity_executable: Path
    source: str


def list_unity_installations(
    root: Path,
    custom_install_file: Path,
    hidden_install_file: Path,
) -> List[UnityInstallation]:
    installations: List[UnityInstallation] = []
    seen_paths: set[str] = set()
    hidden_paths = {str(Path(path).resolve()) for path in _read_hidden_install_paths(hidden_install_file)}

    def add_installation(candidate: UnityInstallation) -> None:
        resolved = str(candidate.install_path.resolve())
        if resolved in hidden_paths:
            return
        if resolved in seen_paths:
            return
        seen_paths.add(resolved)
        installations.append(candidate)

    if root.exists():
        for entry in sorted(root.iterdir()):
            installation = _discover_installation(entry, source="hub-root")
            if installation:
                add_installation(installation)

    custom_paths = _read_custom_install_paths(custom_install_file)
    retained_custom_paths: list[str] = []
    for custom_path in custom_paths:
        installation = _discover_installation(Path(custom_path), source="custom")
        if installation:
            retained_custom_paths.append(str(installation.install_path.resolve()))
            add_installation(installation)
    if sorted(set(retained_custom_paths)) != sorted(set(custom_paths)):
        _write_custom_install_paths(custom_install_file, retained_custom_paths)

    return installations


def register_custom_unity_installation(
    install_path: Path,
    root: Path,
    custom_install_file: Path,
    hidden_install_file: Path,
) -> UnityInstallation:
    installation = _discover_installation(install_path, source="custom")
    if not installation:
        raise UnityRegistryError(f"Could not find a Unity executable under {install_path}")

    resolved = installation.install_path.resolve()
    if _is_under_root(resolved, root):
        root_entry = _root_install_entry_for_path(resolved, root)
        _unhide_installation_path(root_entry, hidden_install_file)
        hub_installation = _discover_installation(root_entry, source="hub-root")
        if hub_installation:
            return hub_installation
        return installation

    custom_paths = _read_custom_install_paths(custom_install_file)
    normalized = str(resolved)
    if normalized not in custom_paths:
        custom_paths.append(normalized)
        _write_custom_install_paths(custom_install_file, custom_paths)

    return installation


def install_unity_version(version: str, cli_path: Path) -> None:
    normalized = version.strip()
    if not normalized:
        raise UnityRegistryError("Unity version is required for installation.")
    _run_hub_cli(cli_path, ["install", "--version", normalized])


def uninstall_unity_version(version: str, cli_path: Path) -> None:
    normalized = version.strip()
    if not normalized:
        raise UnityRegistryError("Unity version is required for uninstallation.")
    _run_hub_cli(cli_path, ["uninstall", "--version", normalized])


def remove_unity_installation(
    version: str,
    root: Path,
    custom_install_file: Path,
    hidden_install_file: Path,
    preferred_source: Optional[str] = None,
) -> None:
    normalized = version.strip()
    if not normalized:
        raise UnityRegistryError("Unity version is required for uninstallation.")

    installation = find_unity_installation_by_version(
        normalized,
        root,
        custom_install_file,
        hidden_install_file,
        preferred_source=preferred_source,
    )
    if not installation:
        raise UnityRegistryError(f"Unity version {normalized} is not installed.")

    if installation.source == "custom":
        _remove_custom_installation_by_version(normalized, custom_install_file)
        return

    _hide_installation_path(installation.install_path, hidden_install_file)


def _discover_installation(entry: Path, source: str) -> Optional[UnityInstallation]:
    if not entry.exists():
        return None

    for candidate in _candidate_directories(entry):
        executable = _find_executable_within(candidate)
        if not executable:
            continue
        version = _detect_version_from_install(executable, candidate)
        if not version:
            continue
        return UnityInstallation(
            version=version,
            install_path=candidate,
            unity_executable=executable,
            source=source,
        )
    return None


def _candidate_directories(entry: Path) -> Iterable[Path]:
    seen: set[str] = set()
    candidates: list[Path] = []

    def append_candidate(path: Path) -> None:
        resolved = str(path.resolve())
        if resolved in seen:
            return
        seen.add(resolved)
        candidates.append(path)

    append_candidate(entry)
    if entry.is_file():
        # Only broaden search for direct Unity binary paths.
        if entry.name == "Unity":
            append_candidate(entry.parent)
            append_candidate(entry.parent.parent)
            append_candidate(entry.parent.parent.parent)
    if entry.is_dir():
        possible_app = entry / "Unity.app"
        if possible_app.exists():
            append_candidate(possible_app)
    return candidates


def _find_executable_within(install_dir: Path) -> Optional[Path]:
    if install_dir.exists() and install_dir.is_file():
        if install_dir.name == "Unity" and os.access(install_dir, os.X_OK):
            return install_dir
        return None

    if install_dir.suffix == ".app":
        candidate = install_dir / "Contents" / "MacOS" / "Unity"
        if candidate.exists() and candidate.is_file():
            return candidate

    candidates = [
        install_dir / "Unity.app" / "Contents" / "MacOS" / "Unity",
        install_dir / "Unity",
    ]
    for candidate in candidates:
        if candidate.exists() and candidate.is_file() and os.access(candidate, os.X_OK):
            return candidate
    return None


def _detect_version_from_install(executable: Path, base_dir: Path) -> Optional[str]:
    version = _detect_version_from_executable(executable)
    app_bundle = _find_app_bundle(executable)

    for candidate in (
        _extract_unity_version(version),
        _extract_unity_version(base_dir.name),
        _extract_unity_version(app_bundle.name if app_bundle else None),
        _extract_unity_version(str(base_dir)),
        _extract_unity_version(str(app_bundle) if app_bundle else None),
    ):
        if candidate:
            return candidate

    if version:
        return version
    name = base_dir.name
    if name:
        return name
    return None


def _detect_version_from_executable(executable: Path) -> Optional[str]:
    app_bundle = _find_app_bundle(executable)
    if not app_bundle:
        return None
    info_plist = app_bundle / "Contents" / "Info.plist"
    if not info_plist.exists():
        return None
    try:
        with info_plist.open("rb") as handle:
            data = plistlib.load(handle)
    except (OSError, plistlib.InvalidFileException):
        return None
    version = data.get("CFBundleShortVersionString")
    if isinstance(version, str):
        return version
    return None


def _find_app_bundle(path: Path) -> Optional[Path]:
    for ancestor in path.parents:
        if ancestor.suffix == ".app":
            return ancestor
    return None


def _extract_unity_version(value: Optional[str]) -> Optional[str]:
    if not value:
        return None
    lowered = value.strip().lower()
    if not lowered:
        return None
    match = re.search(r"\d+\.\d+\.\d+[abcfp]\d+", lowered)
    if not match:
        return None
    return match.group(0)


def _read_custom_install_paths(path: Path) -> List[str]:
    if not path.exists():
        return []
    try:
        with path.open("r", encoding="utf-8") as handle:
            raw = json.load(handle)
    except (OSError, json.JSONDecodeError):
        return []
    if not isinstance(raw, list):
        return []
    paths: List[str] = []
    for candidate in raw:
        if isinstance(candidate, str):
            paths.append(candidate)
    return paths


def _write_custom_install_paths(path: Path, installs: Iterable[str]) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    sorted_installs = sorted({str(Path(item)) for item in installs})
    with path.open("w", encoding="utf-8") as handle:
        json.dump(sorted_installs, handle, indent=2)


def _read_hidden_install_paths(path: Path) -> List[str]:
    if not path.exists():
        return []
    try:
        with path.open("r", encoding="utf-8") as handle:
            raw = json.load(handle)
    except (OSError, json.JSONDecodeError):
        return []
    if not isinstance(raw, list):
        return []
    paths: List[str] = []
    for candidate in raw:
        if isinstance(candidate, str):
            paths.append(candidate)
    return paths


def _write_hidden_install_paths(path: Path, installs: Iterable[str]) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    sorted_installs = sorted({str(Path(item)) for item in installs})
    with path.open("w", encoding="utf-8") as handle:
        json.dump(sorted_installs, handle, indent=2)


def _hide_installation_path(path: Path, hidden_install_file: Path) -> None:
    hidden_paths = _read_hidden_install_paths(hidden_install_file)
    resolved = str(path.resolve())
    if resolved not in hidden_paths:
        hidden_paths.append(resolved)
        _write_hidden_install_paths(hidden_install_file, hidden_paths)


def _unhide_installation_path(path: Path, hidden_install_file: Path) -> None:
    hidden_paths = _read_hidden_install_paths(hidden_install_file)
    resolved = str(path.resolve())
    retained_paths: list[str] = []
    removed = False
    for item in hidden_paths:
        if str(Path(item).resolve()) == resolved:
            removed = True
            continue
        retained_paths.append(item)
    if removed:
        _write_hidden_install_paths(hidden_install_file, retained_paths)


def _remove_custom_installation_by_version(version: str, custom_install_file: Path) -> None:
    normalized = version.strip().lower()
    if not normalized:
        raise UnityRegistryError("Unity version is required for uninstallation.")

    existing_paths = _read_custom_install_paths(custom_install_file)
    kept_paths: List[str] = []
    removed = False

    for raw_path in existing_paths:
        installation = _discover_installation(Path(raw_path), source="custom")
        if installation and installation.version.strip().lower() == normalized:
            removed = True
            continue
        kept_paths.append(raw_path)

    if not removed:
        raise UnityRegistryError(f"Unity version {version} is not a registered local installation.")

    _write_custom_install_paths(custom_install_file, kept_paths)


def remove_custom_installation_by_path(target_path: Path, custom_install_file: Path) -> None:
    resolved_target = str(target_path.resolve())
    existing_paths = _read_custom_install_paths(custom_install_file)
    kept_paths: List[str] = []
    removed = False

    for raw_path in existing_paths:
        if str(Path(raw_path).resolve()) == resolved_target:
            removed = True
            continue
        kept_paths.append(raw_path)

    if not removed:
        raise UnityRegistryError(f"Local Unity installation not registered: {target_path}")

    _write_custom_install_paths(custom_install_file, kept_paths)


def _is_under_root(target: Path, root: Path) -> bool:
    try:
        target.resolve().relative_to(root.resolve())
        return True
    except Exception:
        return False


def _root_install_entry_for_path(target: Path, root: Path) -> Path:
    relative = target.resolve().relative_to(root.resolve())
    if not relative.parts:
        return root.resolve()
    return (root.resolve() / relative.parts[0]).resolve()


def _run_hub_cli(cli_path: Path, args: Iterable[str]) -> None:
    if not cli_path.exists():
        raise UnityRegistryError(f"Unity Hub CLI not found at {cli_path}")
    cmd = [str(cli_path), "--", "--headless", *args]
    try:
        subprocess.run(cmd, check=True)
    except subprocess.CalledProcessError as exc:
        raise UnityRegistryError(f"Unity Hub command failed: {exc}") from exc
    except OSError as exc:
        raise UnityRegistryError(f"Unable to run Unity Hub CLI: {exc}") from exc


def find_unity_installation_by_version(
    version: str,
    root: Path,
    custom_install_file: Path,
    hidden_install_file: Path,
    preferred_source: Optional[str] = None,
) -> Optional[UnityInstallation]:
    normalized = version.strip().lower()
    if not normalized:
        return None
    normalized_source = preferred_source.strip().lower() if preferred_source else None
    for installation in list_unity_installations(root, custom_install_file, hidden_install_file):
        if installation.version.strip().lower() == normalized:
            if normalized_source and installation.source.strip().lower() != normalized_source:
                continue
            return installation
    return None
