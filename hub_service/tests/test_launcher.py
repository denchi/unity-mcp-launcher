from __future__ import annotations

import json
import os
import subprocess
import tempfile
import unittest
from datetime import datetime, timezone
from pathlib import Path
from unittest.mock import patch

from app.launcher import (
    UnityLaunchError,
    ensure_unity_package_manifest_dependency,
    find_running_unity_project_pid,
    focus_unity_editor_window,
    launch_unity,
    resolve_unity_executable,
)
from app.models import ProjectRecord


class LauncherTests(unittest.TestCase):
    def _make_project_record(self, project_root: Path, unity_path: str) -> ProjectRecord:
        now = datetime.now(timezone.utc)
        return ProjectRecord(
            project_id="project-1",
            name="Project",
            project_path=str(project_root),
            unity_path=unity_path,
            tags=[],
            status="idle",
            last_seen_at=None,
            created_at=now,
            updated_at=now,
        )

    def test_resolve_unity_app_bundle(self) -> None:
        bundle = "/Applications/Unity/Hub/Editor/2023.2.22f1/Unity.app"
        resolved = resolve_unity_executable(bundle)
        self.assertEqual(resolved, bundle + "/Contents/MacOS/Unity")

    def test_resolve_binary_path_passthrough(self) -> None:
        binary = "/Applications/Unity/Hub/Editor/2023.2.22f1/Unity.app/Contents/MacOS/Unity"
        resolved = resolve_unity_executable(binary)
        self.assertEqual(resolved, binary)

    def test_resolve_local_temp_bundle(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            app_dir = Path(tmp) / "Unity.app" / "Contents" / "MacOS"
            app_dir.mkdir(parents=True)
            exe = app_dir / "Unity"
            exe.write_text("#!/bin/sh\nexit 0\n")
            os.chmod(exe, 0o755)
            resolved = resolve_unity_executable(str(Path(tmp) / "Unity.app"))
            self.assertEqual(resolved, str(exe))

    def test_find_running_unity_project_pid_matches_project_path(self) -> None:
        project_path = "/tmp/My Project"
        command = (
            "123 /Applications/Unity/Hub/Editor/6000.0.0f1/Unity.app/Contents/MacOS/Unity "
            "-projectPath '/tmp/My Project' -executeMethod Mcp.HubBootstrap.Start"
        )
        completed = subprocess.CompletedProcess(
            args=["ps", "-axo", "pid=,command="],
            returncode=0,
            stdout=command + "\n",
            stderr="",
        )

        with patch("app.launcher.subprocess.run", return_value=completed):
            pid = find_running_unity_project_pid(project_path)

        self.assertEqual(pid, 123)

    def test_focus_unity_editor_window_uses_osascript(self) -> None:
        completed = subprocess.CompletedProcess(
            args=["osascript"],
            returncode=0,
            stdout="",
            stderr="",
        )

        with patch("app.launcher.subprocess.run", return_value=completed) as run_mock:
            focus_unity_editor_window(2222)

        run_args = run_mock.call_args.args[0]
        self.assertEqual(run_args[0], "osascript")
        self.assertEqual(run_args[1], "-e")
        self.assertIn("unix id is 2222", run_args[2])

    def test_focus_unity_editor_window_requires_pid(self) -> None:
        with self.assertRaises(UnityLaunchError):
            focus_unity_editor_window(None)

    def test_focus_unity_editor_window_raises_on_script_failure(self) -> None:
        completed = subprocess.CompletedProcess(
            args=["osascript"],
            returncode=1,
            stdout="",
            stderr="not authorized",
        )
        with patch("app.launcher.subprocess.run", return_value=completed):
            with self.assertRaises(UnityLaunchError) as raised:
                focus_unity_editor_window(3333)

        self.assertIn("3333", str(raised.exception))

    def test_manifest_dependency_added_when_missing(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            project_root = Path(tmp) / "ExampleProject"
            packages_dir = project_root / "Packages"
            packages_dir.mkdir(parents=True)
            manifest_path = packages_dir / "manifest.json"
            manifest_path.write_text(
                json.dumps(
                    {
                        "dependencies": {
                            "com.unity.textmeshpro": "3.0.6"
                        }
                    },
                    indent=2,
                )
                + "\n",
                encoding="utf-8",
            )

            changed = ensure_unity_package_manifest_dependency(
                project_path=str(project_root),
                package_name="com.example.unitymcp",
                package_git_url="https://github.com/example/unity-mcp.git?path=/Packages/com.example.unitymcp#v1.2.3",
            )

            self.assertTrue(changed)
            updated = json.loads(manifest_path.read_text(encoding="utf-8"))
            self.assertEqual(
                updated["dependencies"]["com.example.unitymcp"],
                "https://github.com/example/unity-mcp.git?path=/Packages/com.example.unitymcp#v1.2.3",
            )

    def test_manifest_dependency_added_when_url_exists_under_different_name(self) -> None:
        url = "https://github.com/example/unity-mcp.git?path=/Packages/com.example.unitymcp#v1.2.3"
        with tempfile.TemporaryDirectory() as tmp:
            project_root = Path(tmp) / "ExampleProject"
            packages_dir = project_root / "Packages"
            packages_dir.mkdir(parents=True)
            manifest_path = packages_dir / "manifest.json"
            original = {
                "dependencies": {
                    "com.other.alias": url,
                    "com.unity.textmeshpro": "3.0.6",
                }
            }
            manifest_path.write_text(json.dumps(original, indent=2) + "\n", encoding="utf-8")

            changed = ensure_unity_package_manifest_dependency(
                project_path=str(project_root),
                package_name="com.example.unitymcp",
                package_git_url=url,
            )

            self.assertTrue(changed)
            updated = json.loads(manifest_path.read_text(encoding="utf-8"))
            self.assertEqual(updated["dependencies"]["com.example.unitymcp"], url)
            self.assertEqual(updated["dependencies"]["com.other.alias"], url)

    def test_manifest_dependency_updates_existing_name_with_new_url(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            project_root = Path(tmp) / "ExampleProject"
            packages_dir = project_root / "Packages"
            packages_dir.mkdir(parents=True)
            manifest_path = packages_dir / "manifest.json"
            manifest_path.write_text(
                json.dumps(
                    {
                        "dependencies": {
                            "com.example.unitymcp": "https://github.com/example/unity-mcp.git#old-ref"
                        }
                    },
                    indent=2,
                )
                + "\n",
                encoding="utf-8",
            )

            new_url = "https://github.com/example/unity-mcp.git?path=/Packages/com.example.unitymcp#v1.2.3"
            changed = ensure_unity_package_manifest_dependency(
                project_path=str(project_root),
                package_name="com.example.unitymcp",
                package_git_url=new_url,
            )

            self.assertTrue(changed)
            updated = json.loads(manifest_path.read_text(encoding="utf-8"))
            self.assertEqual(updated["dependencies"]["com.example.unitymcp"], new_url)

    def test_manifest_dependency_errors_when_manifest_missing(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            project_root = Path(tmp) / "ExampleProject"
            (project_root / "Packages").mkdir(parents=True)

            with self.assertRaises(UnityLaunchError):
                ensure_unity_package_manifest_dependency(
                    project_path=str(project_root),
                    package_name="com.example.unitymcp",
                    package_git_url="https://github.com/example/unity-mcp.git?path=/Packages/com.example.unitymcp#v1.2.3",
                )

    def test_launch_unity_refreshes_packages_when_manifest_patched_and_execute_method_used(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            project_root = Path(tmp) / "ExampleProject"
            packages_dir = project_root / "Packages"
            packages_dir.mkdir(parents=True)
            (packages_dir / "manifest.json").write_text(
                json.dumps({"dependencies": {"com.unity.textmeshpro": "3.0.6"}}, indent=2) + "\n",
                encoding="utf-8",
            )
            unity_executable = Path(tmp) / "Unity"
            unity_executable.write_text("#!/bin/sh\nexit 0\n", encoding="utf-8")
            os.chmod(unity_executable, 0o755)
            project = self._make_project_record(project_root, str(unity_executable))

            with patch("app.launcher.subprocess.run") as run_mock, patch("app.launcher.subprocess.Popen") as popen_mock:
                run_mock.return_value.returncode = 0
                popen_mock.return_value.pid = 4321

                pid = launch_unity(
                    project=project,
                    headless=False,
                    execute_method="Mcp.HubBootstrap.Start",
                    package_name="com.example.unitymcp",
                    package_git_url="https://github.com/example/unity-mcp.git?path=/Packages/com.example.unitymcp#v1.2.3",
                )

                self.assertEqual(pid, 4321)
                self.assertEqual(run_mock.call_count, 2)
                refresh_args = run_mock.call_args_list[0].args[0]
                self.assertIn("-batchmode", refresh_args)
                self.assertIn("-quit", refresh_args)
                self.assertIn(str(project_root), refresh_args)
                self.assertNotIn("-executeMethod", refresh_args)

                warmup_args = run_mock.call_args_list[1].args[0]
                self.assertIn("-executeMethod", warmup_args)
                self.assertIn("Mcp.HubBootstrap.Start", warmup_args)

                popen_mock.assert_called_once()
                launch_args = popen_mock.call_args.args[0]
                self.assertIn("-executeMethod", launch_args)
                self.assertIn("Mcp.HubBootstrap.Start", launch_args)

    def test_launch_unity_skips_refresh_when_dependency_already_present(self) -> None:
        url = "https://github.com/example/unity-mcp.git?path=/Packages/com.example.unitymcp#v1.2.3"
        with tempfile.TemporaryDirectory() as tmp:
            project_root = Path(tmp) / "ExampleProject"
            packages_dir = project_root / "Packages"
            packages_dir.mkdir(parents=True)
            (packages_dir / "manifest.json").write_text(
                json.dumps({"dependencies": {"com.example.unitymcp": url}}, indent=2) + "\n",
                encoding="utf-8",
            )
            unity_executable = Path(tmp) / "Unity"
            unity_executable.write_text("#!/bin/sh\nexit 0\n", encoding="utf-8")
            os.chmod(unity_executable, 0o755)
            project = self._make_project_record(project_root, str(unity_executable))

            with patch("app.launcher.subprocess.run") as run_mock, patch("app.launcher.subprocess.Popen") as popen_mock:
                popen_mock.return_value.pid = 5432

                pid = launch_unity(
                    project=project,
                    headless=False,
                    execute_method="Mcp.HubBootstrap.Start",
                    package_name="com.example.unitymcp",
                    package_git_url=url,
                )

                self.assertEqual(pid, 5432)
                run_mock.assert_not_called()
                popen_mock.assert_called_once()

    def test_launch_unity_manifest_patch_without_execute_method_runs_no_prewarm_steps(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            project_root = Path(tmp) / "ExampleProject"
            packages_dir = project_root / "Packages"
            packages_dir.mkdir(parents=True)
            (packages_dir / "manifest.json").write_text(
                json.dumps({"dependencies": {"com.unity.textmeshpro": "3.0.6"}}, indent=2) + "\n",
                encoding="utf-8",
            )
            unity_executable = Path(tmp) / "Unity"
            unity_executable.write_text("#!/bin/sh\nexit 0\n", encoding="utf-8")
            os.chmod(unity_executable, 0o755)
            project = self._make_project_record(project_root, str(unity_executable))

            with patch("app.launcher.subprocess.run") as run_mock, patch("app.launcher.subprocess.Popen") as popen_mock:
                run_mock.return_value.returncode = 0
                popen_mock.return_value.pid = 6543

                pid = launch_unity(
                    project=project,
                    headless=False,
                    execute_method=None,
                    package_name="com.example.unitymcp",
                    package_git_url="https://github.com/example/unity-mcp.git?path=/Packages/com.example.unitymcp#v1.2.3",
                )

                self.assertEqual(pid, 6543)
                run_mock.assert_not_called()
                popen_mock.assert_called_once()


if __name__ == "__main__":
    unittest.main()
