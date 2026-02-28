from __future__ import annotations

import json
import plistlib
import tempfile
import unittest
from pathlib import Path

from app.unity_registry import (
    list_unity_installations,
    register_custom_unity_installation,
    remove_unity_installation,
)


class UnityRegistryTests(unittest.TestCase):
    def test_list_installations_prunes_invalid_custom_entries(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            custom_file = root / "custom.json"
            hidden_file = root / "hidden.json"
            invalid_file = root / ".DS_Store"
            invalid_file.write_text("junk", encoding="utf-8")

            app_path = root / "Unity.app"
            info_plist = app_path / "Contents" / "Info.plist"
            executable = app_path / "Contents" / "MacOS" / "Unity"
            executable.parent.mkdir(parents=True, exist_ok=True)
            info_plist.parent.mkdir(parents=True, exist_ok=True)
            executable.write_text("#!/bin/sh\n", encoding="utf-8")
            executable.chmod(0o755)
            with info_plist.open("wb") as handle:
                plistlib.dump({"CFBundleShortVersionString": "2022.3.10f1"}, handle)

            custom_file.write_text(
                json.dumps([str(invalid_file), str(app_path)]),
                encoding="utf-8",
            )

            installations = list_unity_installations(root / "missing", custom_file, hidden_file)
            self.assertEqual(len(installations), 1)
            self.assertEqual(installations[0].version, "2022.3.10f1")
            self.assertEqual(installations[0].source, "custom")

            stored_paths = json.loads(custom_file.read_text(encoding="utf-8"))
            self.assertEqual(stored_paths, [str(app_path.resolve())])

    def test_remove_hub_installation_hides_it_without_uninstall(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp) / "hub_root"
            custom_file = Path(tmp) / "custom.json"
            hidden_file = Path(tmp) / "hidden.json"

            app_path = root / "2022.3.10f1" / "Unity.app"
            info_plist = app_path / "Contents" / "Info.plist"
            executable = app_path / "Contents" / "MacOS" / "Unity"
            executable.parent.mkdir(parents=True, exist_ok=True)
            info_plist.parent.mkdir(parents=True, exist_ok=True)
            executable.write_text("#!/bin/sh\n", encoding="utf-8")
            executable.chmod(0o755)
            with info_plist.open("wb") as handle:
                plistlib.dump({"CFBundleShortVersionString": "2022.3.10f1"}, handle)

            before = list_unity_installations(root, custom_file, hidden_file)
            self.assertEqual(len(before), 1)

            remove_unity_installation(
                "2022.3.10f1",
                root,
                custom_file,
                hidden_file,
                preferred_source="hub-root",
            )

            after = list_unity_installations(root, custom_file, hidden_file)
            self.assertEqual(len(after), 0)

    def test_registering_hidden_hub_installation_unhides_it(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp) / "hub_root"
            custom_file = Path(tmp) / "custom.json"
            hidden_file = Path(tmp) / "hidden.json"

            app_path = root / "2022.3.10f1" / "Unity.app"
            info_plist = app_path / "Contents" / "Info.plist"
            executable = app_path / "Contents" / "MacOS" / "Unity"
            executable.parent.mkdir(parents=True, exist_ok=True)
            info_plist.parent.mkdir(parents=True, exist_ok=True)
            executable.write_text("#!/bin/sh\n", encoding="utf-8")
            executable.chmod(0o755)
            with info_plist.open("wb") as handle:
                plistlib.dump({"CFBundleShortVersionString": "2022.3.10f1"}, handle)

            hidden_file.write_text(
                json.dumps([str((root / "2022.3.10f1").resolve())]),
                encoding="utf-8",
            )

            installation = register_custom_unity_installation(
                app_path,
                root,
                custom_file,
                hidden_file,
            )
            self.assertEqual(installation.source, "hub-root")

            listed = list_unity_installations(root, custom_file, hidden_file)
            self.assertEqual(len(listed), 1)
            self.assertEqual(listed[0].version, "2022.3.10f1")

            stored_hidden = json.loads(hidden_file.read_text(encoding="utf-8"))
            self.assertEqual(stored_hidden, [])

    def test_detects_version_from_path_when_plist_lacks_suffix(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            custom_file = root / "custom.json"
            hidden_file = root / "hidden.json"

            app_path = root / "2022.3.10f1" / "Unity.app"
            info_plist = app_path / "Contents" / "Info.plist"
            executable = app_path / "Contents" / "MacOS" / "Unity"
            executable.parent.mkdir(parents=True, exist_ok=True)
            info_plist.parent.mkdir(parents=True, exist_ok=True)
            executable.write_text("#!/bin/sh\n", encoding="utf-8")
            executable.chmod(0o755)
            with info_plist.open("wb") as handle:
                plistlib.dump({"CFBundleShortVersionString": "2022.3.10"}, handle)

            custom_file.write_text(json.dumps([str(app_path)]), encoding="utf-8")

            installations = list_unity_installations(root / "missing", custom_file, hidden_file)
            self.assertEqual(len(installations), 1)
            self.assertEqual(installations[0].version, "2022.3.10f1")


if __name__ == "__main__":
    unittest.main()
