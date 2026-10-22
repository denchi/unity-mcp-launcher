# Unity MCP Hub

macOS menu-bar app that registers Unity projects, launches them in a matching local Unity Editor, and exposes the active session to Cursor, Codex, and other MCP clients through a local stdio gateway.

Unity MCP Hub is a macOS app that manages Unity projects and launches them in a hub-based MCP workflow.

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
- Python 3.10+ recommended (the MCP gateway dependency setup requires 3.10+)
- Unity installed locally

Python packages:

- Hub service: `fastapi`, `uvicorn`, `httpx`, `pydantic` (`hub_service/requirements.txt`)
- MCP gateway: `mcp`, `httpx` (`hub_mcp_gateway/requirements.txt`)

## Install and build

1. Clone and build the macOS app:

```bash
git clone <this-repo-url>
cd <repo-folder>
swift build
```

2. Run the app:

```bash
swift run UnityMCPHubApp
```

The app can start the local hub service automatically when syncing or launching projects. When it does, it also tries to `pip install --user` any missing hub-service dependencies, and the gateway dependencies when Python 3.10+ is available.
In development mode (`swift run`) a terminal session is expected.

3. Install the Python pieces yourself when you want to run them outside the app:

```bash
cd hub_service
python3 -m pip install -r requirements.txt

cd ../hub_mcp_gateway
python3 -m pip install -r requirements.txt
```

Release build of the app bundle:

```bash
swift build -c release
```

`package_macos_app.sh` does that release build and wraps it. See [Shipping / Installation](#shipping--installation-best-practice).

## How To Use

1. Open **Settings** and set:
   - Hub URL (default: `http://127.0.0.1:8787`)
   - Hub token (auto-generated per machine; stored in macOS Keychain)
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
   - If Unity is already running for the selected project, the UI shows **Connect to Running Unity** instead of forcing a relaunch.
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

The gateway speaks MCP over stdio (`HUB_MCP_TRANSPORT` defaults to `stdio`). Leave that process attached to the client that launches it. Cursor and Codex start it themselves; see below.

## Connect from Cursor and Codex

The app does not register itself with a client. Cursor and Codex each start `hub_mcp_gateway/run.py`, which runs the FastMCP server `unity-mcp-hub-gateway` on stdio and calls the hub at `HUB_MCP_HUB_URL` (default `http://127.0.0.1:8787`).

Start the hub first, either by opening Unity MCP Hub (it launches `hub_service/run.py` when you sync or launch) or by running the hub service manually.

The gateway sends `X-Hub-Token` on hub calls. It reads that token from `HUB_MCP_HUB_TOKEN`, then `HUB_AUTH_TOKEN_FILE`, then `~/.unity-mcp-hub/auth_token`. It does not read the macOS Keychain.

- When the app starts the hub, it passes the Keychain token as `HUB_AUTH_TOKEN`. That value wins over the token file. Copy **Settings → Hub Token** into `HUB_MCP_HUB_TOKEN`.
- When you start `hub_service/run.py` yourself and do not set `HUB_AUTH_TOKEN`, the service loads or creates `~/.unity-mcp-hub/auth_token` and the gateway reads that same file. `HUB_MCP_HUB_TOKEN` can stay unset.

`python3` must be able to import `mcp` and `httpx`. Use an absolute path to `run.py` so the script directory is on `sys.path`.

### Cursor

Add this to `~/.cursor/mcp.json` (every project) or `.cursor/mcp.json` in one project. Replace the path and, when the app owns the hub, the token.

```json
{
  "mcpServers": {
    "unity-mcp-hub": {
      "command": "python3",
      "args": ["/absolute/path/to/unity-mcp-launcher/hub_mcp_gateway/run.py"],
      "env": {
        "HUB_MCP_HUB_URL": "http://127.0.0.1:8787",
        "HUB_MCP_HUB_TOKEN": "<hub token>"
      }
    }
  }
}
```

Reload MCP servers in Cursor after saving. Omit `HUB_MCP_HUB_TOKEN` only when the gateway and the hub share `~/.unity-mcp-hub/auth_token`.

### Codex

Codex (CLI, desktop, and IDE extension) reads `~/.codex/config.toml`, or `.codex/config.toml` in a trusted project. Either add the server from the shell:

```bash
codex mcp add unity-mcp-hub \
  --env HUB_MCP_HUB_URL=http://127.0.0.1:8787 \
  --env HUB_MCP_HUB_TOKEN=<hub token> \
  -- python3 /absolute/path/to/unity-mcp-launcher/hub_mcp_gateway/run.py
```

or edit the config directly:

```toml
[mcp_servers.unity-mcp-hub]
command = "python3"
args = ["/absolute/path/to/unity-mcp-launcher/hub_mcp_gateway/run.py"]

[mcp_servers.unity-mcp-hub.env]
HUB_MCP_HUB_URL = "http://127.0.0.1:8787"
HUB_MCP_HUB_TOKEN = "<hub token>"
```

Check it with `codex mcp list` or `/mcp` in the Codex TUI.

### Gateway environment

| Variable | Default | Role |
| --- | --- | --- |
| `HUB_MCP_HUB_URL` | `http://127.0.0.1:8787` | Hub base URL |
| `HUB_MCP_HUB_TOKEN` | unset | Hub token. If unset, the gateway reads the token file |
| `HUB_AUTH_TOKEN_FILE` | `~/.unity-mcp-hub/auth_token` | Token file shared with a manually started hub |
| `HUB_MCP_CLIENT_ID` | hostname slug | `client_id` sent by `select_project` and used to filter `list_sessions` |
| `HUB_MCP_TIMEOUT_SECONDS` | `20` | HTTP timeout for hub calls |
| `HUB_MCP_DEFAULT_EXECUTE_METHOD` | empty | Fallback Unity `-executeMethod` when `select_project` is called without one |
| `HUB_MCP_TRANSPORT` | `stdio` | Transport passed to `mcp.run`. Leave this as `stdio` for Cursor and Codex |

A usual call order is `list_projects`, `select_project`, `focus_unity_window`, `list_unity_tools`, then `call_unity_tool`. Unity tool calls use the gateway's active session unless `session_id` is passed.

## MCP tools

These are the tools registered in `hub_mcp_gateway/server.py`. Names and arguments match that file. `list_unity_tools` and `call_unity_tool` forward to the Unity package bridge; this repository does not define those Unity-side tool names.

| Tool | What it does |
| --- | --- |
| `hub_health` | `GET /health` on the hub. No token. |
| `list_projects` | Projects registered in the hub. |
| `list_sessions` | Sessions for this gateway's `HUB_MCP_CLIENT_ID`. `include_dead` defaults to false. |
| `select_project` | Selects or launches a session and stores it as the active session. Arguments: `project_id`, `name`, `tags`, `most_recent` (false), `auto_launch` (true), `attach_if_running` (true), `launch_headless` (false), `execute_method`. |
| `use_session` | Points later Unity calls at an existing `session_id`. |
| `current_session` | Returns the active session, or empty fields when none is set. |
| `clear_session` | Clears the gateway's active-session memory. Does not kill the hub session. |
| `kill_session` | Kills a hub session (`session_id` optional, uses the active session). `force` defaults to false. A recent starting session is left alone unless `force` is true. |
| `focus_unity_window` | Brings that session's Unity Editor window forward. `session_id` optional. |
| `list_unity_tools` | Forwards `GET /tools` to the session bridge. `session_id` optional. |
| `call_unity_tool` | Forwards `POST /tools/call` with `tool_name` and `arguments`. `session_id` optional. |
| `forward_unity_http` | Forwards an HTTP call to the session agent or bridge. `path` is required. `method` is `GET`, `POST`, `PUT`, `PATCH`, or `DELETE` (default `POST`). `target` is `agent` or `bridge` (default `agent`). Optional `body` and `session_id`. |

## Security

The hub is a local control plane. Treat its token as a credential for every registered Unity project.

- The service binds to `127.0.0.1` port `8787` unless `HUB_HOST` or `HUB_PORT` is set. Leave it on loopback. A non-loopback bind exposes launch, kill, and HTTP-forward endpoints to anything that can present the token.
- `GET /health` is unauthenticated. Every other control route requires the header `X-Hub-Token`.
- The macOS app keeps its token in the Keychain (`com.denchi.unity-mcp-hub` / `hub-auth-token`, this device only) and passes it to the hub as `HUB_AUTH_TOKEN`. A hub started without that variable writes `~/.unity-mcp-hub/auth_token` with mode `0600`.
- `call_unity_tool` and `forward_unity_http` proxy into the Unity agent or bridge for the selected session. `select_project` can launch Unity and can rewrite `Packages/manifest.json`.
- Do not commit the hub token. Prefer the token file, or an environment variable, over pasting it into a shared `.cursor/mcp.json` or `.codex/config.toml`.

## Useful Commands

From repo root:

```bash
make run
make run-hub
make run-hub-mcp
make build
make test-hub
make test-gateway-smoke
make ship-check
make package-macos VERSION=v0.1.5
```

The Makefile targets `cd` to `/Users/denis/dev/unity-mcp-launcher`. On another checkout, use the `swift` and `python3` commands in this README instead.

## Shipping / Installation (best practice)

For end users, distribute a signed/notarized `.dmg` containing the `.app` bundle.

Build local `.app` + `.dmg`:

```bash
./package_macos_app.sh v0.1.5
```

Build signed + notarized DMG for distribution:

```bash
export SIGN_IDENTITY="Developer ID Application: YOUR NAME (TEAMID)"
export BUNDLE_ID="com.denchi.unity-mcp-hub"
export NOTARIZE=1
# Preferred if configured:
export NOTARY_KEYCHAIN_PROFILE="AC_NOTARY_PROFILE"
# Or use Apple ID auth:
# export APPLE_ID="you@example.com"
# export TEAM_ID="TEAMID1234"
# export APP_SPECIFIC_PASSWORD="xxxx-xxxx-xxxx-xxxx"
./package_macos_app.sh v0.1.5
```

Output:

- `dist/Unity MCP Hub.app`
- `dist/UnityMCPHub-v0.1.5.dmg`

Install flow: user opens the DMG and drags **Unity MCP Hub.app** to **Applications**.

## Notes

- Project versions are read from project files, not from the database.
- Session selection is idempotent for active sessions to avoid duplicate Unity launches.
- Session kill supports a startup grace period unless force-killed.

## Licence

Released under the [MIT License](LICENSE). Copyright 2026 Denis Chiriac / Death By Gravity Studio.
