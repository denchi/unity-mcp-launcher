from __future__ import annotations

from pathlib import Path
from typing import Optional, Union


def detect_project_unity_version(project_path: Union[str, Path]) -> Optional[str]:
    candidates = [
        Path(project_path) / "ProjectSettings" / "ProjectVersion.txt",
        Path(project_path) / "ProjectVersion.txt",
    ]

    for path in candidates:
        if not path.exists() or not path.is_file():
            continue

        try:
            content = path.read_text(encoding="utf-8")
        except OSError:
            continue

        preferred = None
        fallback = None
        for line in content.splitlines():
            if ":" not in line:
                continue
            key, value = line.split(":", 1)
            key = key.strip()
            value = value.strip()
            if not value:
                continue
            if key == "m_EditorVersion":
                preferred = value
                break
            if key == "m_EditorVersionWithRevision":
                fallback = value

        version = preferred or fallback
        if version:
            return version

    return None
