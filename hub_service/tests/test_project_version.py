from __future__ import annotations

import tempfile
import unittest
from pathlib import Path

from app.project_version import detect_project_unity_version


class ProjectVersionTests(unittest.TestCase):
    def test_detects_editor_version(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            project_root = Path(tmp)
            settings_dir = project_root / "ProjectSettings"
            settings_dir.mkdir(parents=True, exist_ok=True)
            (settings_dir / "ProjectVersion.txt").write_text(
                "m_EditorVersion: 2023.3.0f1\n",
                encoding="utf-8",
            )

            version = detect_project_unity_version(project_root)
            self.assertEqual(version, "2023.3.0f1")

    def test_falls_back_to_project_root_when_project_settings_file_missing(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            project_root = Path(tmp)
            (project_root / "ProjectVersion.txt").write_text(
                "m_EditorVersion: 2021.3.10f1\n",
                encoding="utf-8",
            )

            version = detect_project_unity_version(project_root)
            self.assertEqual(version, "2021.3.10f1")

    def test_falls_back_to_revision_when_editor_version_missing(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            project_root = Path(tmp)
            (project_root / "ProjectVersion.txt").write_text(
                "m_EditorVersionWithRevision: 2023.2.2f1 (revision)\n",
                encoding="utf-8",
            )

            version = detect_project_unity_version(project_root)
            self.assertEqual(version, "2023.2.2f1 (revision)")

    def test_returns_none_when_file_missing(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            version = detect_project_unity_version(Path(tmp))
            self.assertIsNone(version)
