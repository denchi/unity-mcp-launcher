# Unity MCP Launcher

Unity MCP Launcher is a macOS app that manages Unity projects and launches them in a hub-based MCP workflow.

It provides:

- A desktop UI to register Unity projects
- Unity version detection from `ProjectSettings/ProjectVersion.txt`
- Local Unity installation management (detect, add, remove from hub list)
- Session-based launch and lifecycle control through a local hub service
- Optional MCP gateway to expose tools to Codex/Cursor/other MCP clients
- Menu bar operation (background app with status bar icon)

## Components

This repository includes:

- `Sources/UnityMCPHubApp` - macOS SwiftUI desktop app
- `hub_service` - FastAPI + SQLite backend used by the app
- `hub_mcp_gateway` - MCP server that forwards to the active hub session

External component required on the Unity side:

- Unity package repo: [UnityGPTActions](https://github.com/denchi/UnityGPTActions)
- SSH clone URL: `git@github.com:denchi/UnityGPTActions.git`
- Default package reference used by the hub:
  - Package name: `com.deathbygravitystudio.gptactions`
  - Git URL: `https://github.com/denchi/UnityGPTActions.git#feature/mcp`

## Requirements

- macOS 13+
- Xcode 15+ (or Swift 6 toolchain)
- Python 3.10+ recommended
- Unity installed locally

## Quick Start

1. Clone and build:

```bash
git clone <this-repo-url>
cd <repo-folder>
swift build
```

2. Run the app:

```bash
swift run UnityMCPHubApp
```

The app can start the local hub service automatically when syncing or launching projects.
In development mode (`swift run`) a terminal session is expected.

## How To Use

1. Open **Settings** and set:
   - Hub URL (default: `http://127.0.0.1:8787`)
   - Hub token (default: `dev-shared-secret`)
   - Optional Unity package override (name + git URL)
2. Add one or more Unity projects.
3. Open **Unity Installations**:
   - Browse/add local Unity installs
   - Remove installs from the hub list
4. In project details:
   - `Unity Version` is read from `ProjectSettings/ProjectVersion.txt`
   - Select which installed Unity version to launch with
   - If the required version is not installed, a warning icon is shown
5. Click **Launch Project**.
6. The app lives in the macOS status bar. Click the status icon to show/hide the main UI.

## Unity Side Setup (required)

Your Unity project must include the Unity package that talks to this hub workflow.

Preferred UPM dependency entry in `Packages/manifest.json`:

```json
{
  "dependencies": {
    "com.deathbygravitystudio.gptactions": "https://github.com/denchi/UnityGPTActions.git#feature/mcp"
  }
}
```

The hub can patch `manifest.json` during launch using configured package name/Git URL.

If you need the package source directly:

```bash
git clone git@github.com:denchi/UnityGPTActions.git
```

## Run Backend Services Manually (optional)

Run hub service:

```bash
cd hub_service
python3 -m pip install -r requirements.txt
python3 run.py
```

Run MCP gateway:

```bash
cd hub_mcp_gateway
python3 -m pip install -r requirements.txt
python3 run.py
```

## Useful Commands

From repo root:

```bash
make run
make run-hub
make run-hub-mcp
make build
make test-hub
make package-macos VERSION=v0.1.4
```

## Shipping / Installation (best practice)

For end users, distribute a signed/notarized `.dmg` containing the `.app` bundle.

Build local `.app` + `.dmg`:

```bash
./package_macos_app.sh v0.1.4
```

Output:

- `dist/Unity MCP Launcher.app`
- `dist/UnityMCPLauncher-v0.1.4.dmg`

Install flow: user opens the DMG and drags **Unity MCP Launcher.app** to **Applications**.

## Notes

- Project versions are read from project files, not from the database.
- Session selection is idempotent for active sessions to avoid duplicate Unity launches.
- Session kill supports a startup grace period unless force-killed.
