# Unity MCP Hub (macOS app)

Native macOS SwiftUI app that behaves like a lightweight Unity Hub:

- Add Unity projects to a local registry
- See projects in a searchable list
- Inspect project details and health
- Launch Unity for a selected project (normal or headless)

This is the UI/control-plane shell for your broader "hub + per-project agent" system.

## Hub backend (FastAPI + SQLite)

The repository now also includes a control-plane backend in:

`/Users/denis/dev/unity-mcp-launcher/hub_service`

It provides:

- Project registry
- Session selection + TTL leases
- Unity launch trigger endpoint
- Agent registration + heartbeat
- MCP-style request forwarding to selected project agent

### Install backend deps

```bash
cd /Users/denis/dev/unity-mcp-launcher/hub_service
python3 -m pip install -r requirements.txt
```

### Run backend

```bash
cd /Users/denis/dev/unity-mcp-launcher/hub_service
python3 run.py
```

Defaults:

- `HUB_HOST=127.0.0.1`
- `HUB_PORT=8787`
- `HUB_DB_PATH=./hub_service/hub.db`
- `HUB_AUTH_TOKEN=dev-shared-secret`
- default pre-launch UPM patch:
  - `HUB_UNITY_AGENT_PACKAGE_NAME=com.deathbygravitystudio.gptactions`
  - `HUB_UNITY_AGENT_PACKAGE_GIT_URL=https://github.com/denchi/UnityGPTActions.git#feature/mcp`

On each launch, the hub checks `<project>/Packages/manifest.json` and enforces the package entry for the configured name+URL (adds or updates as needed).

### Core endpoints

- `GET /health`
- `POST /projects`
- `GET /projects`
- `POST /projects/launch`
- `POST /sessions/select`
- `GET /sessions/{session_id}`
- `POST /sessions/{session_id}/renew`
- `POST /sessions/{session_id}/kill`
- `POST /agents/register`
- `POST /agents/heartbeat`
- `POST /sessions/{session_id}/forward`

Send `X-Hub-Token` header for all non-health endpoints.

## Requirements

- macOS 13+
- Swift 6 toolchain (Xcode 15+ or Swift CLI)

## Run

```bash
cd /Users/denis/dev/unity-mcp-launcher
swift run UnityMCPHubApp
```

On startup, the app now verifies Python dependencies and installs missing packages (`--user`) for:

- `hub_service/requirements.txt`
- `hub_mcp_gateway/requirements.txt`

Notes:

- Hub service dependencies are required for app-managed hub startup.
- Hub MCP gateway dependencies are optional during app startup.
- The app auto-discovers Python interpreters (e.g. `python3.10+` in Homebrew/system paths).
- The `mcp` package requires Python `3.10+`, and the app will attempt to install it with a compatible interpreter when available.

## Build

```bash
cd /Users/denis/dev/unity-mcp-launcher
swift build
```

## Use

1. Launch the mac app.
2. In the app's `Hub Connection` section set:
   - `Hub URL` (default `http://127.0.0.1:8787`)
   - `Hub Token` (default `dev-shared-secret`)
   - `Client ID` (any stable ID, for example `denis-mac`)
   - `Default Execute Method` (for ChatGptAssistant: `Mcp.HubBootstrap.Start`)
   - Optional launch preflight:
     - `UPM Package Name` (for example `com.example.unitymcp`)
     - `UPM Git URL` (for example `https://github.com/org/repo.git?path=/Packages/com.example.unitymcp#v1.2.3`)
3. Click `Start Hub` (or just `Test + Sync`, which also auto-starts it).
4. Click `Add Project`.
2. Set:
   - `Name`
   - `Project Path` (Unity project root)
   - `Unity Binary` (e.g. `/Applications/Unity/Hub/Editor/<version>/Unity.app/Contents/MacOS/Unity`)
   - Optional tags
5. Select a project and click `Launch`.
6. After session is active, use forward tests in the detail panel:
   - `Forward Test (Health)` (agent `/mcp/health`)
   - `Forward Test (List Tools)` (bridge `/tools`)
   - `Forward Test (Call Tool)` (bridge `/tools/call`)

Projects are now persisted in the hub's SQLite database (not in local app JSON).

## Unity Agent Bootstrap (starting -> ready)

This repo now includes Unity Editor scripts for hub registration and heartbeat:

- `/Users/denis/dev/unity-mcp-launcher/unity_agent/Editor/UnityMcpHubAgentRuntime.cs`
- `/Users/denis/dev/unity-mcp-launcher/unity_agent/Editor/UnityMcpHubBootstrap.cs`

Copy these files into each Unity project's `Assets/Editor` (or your editor package).

How it works:

1. Hub launches Unity from `POST /sessions/select`.
2. Hub injects env vars (`UNITY_MCP_SESSION_ID`, `UNITY_MCP_LAUNCH_TOKEN`, etc).
3. `UnityMcpHubAgentRuntime` reads env vars, calls `POST /agents/register`, then sends `POST /agents/heartbeat`.
4. Session status transitions from `starting` to `ready` automatically.

For ChatGptAssistant launch integration, set:

`HUB_DEFAULT_EXECUTE_METHOD=Mcp.HubBootstrap.Start`

Default agent endpoint used for forwarding is `http://127.0.0.1:7072` unless `UNITY_MCP_AGENT_ENDPOINT` is provided.

## Run Actions (Codex Run Button)

Use these from Codex app Run:

```bash
make run
```

Other useful actions:

```bash
make run-hub
make run-hub-mcp
make build
make test-hub
```

## Connect via MCP (Cursor / Codex / other MCP clients)

This repo includes a unified MCP gateway at:

`/Users/denis/dev/unity-mcp-launcher/hub_mcp_gateway`

It exposes both:

- Hub-level tools (`list_projects`, `select_project`, `list_sessions`, `kill_session`)
- Unity tools routed to active session (`list_unity_tools`, `call_unity_tool`)

### Install gateway deps

```bash
cd /Users/denis/dev/unity-mcp-launcher/hub_mcp_gateway
python3 -m pip install -r requirements.txt
```

### MCP server config example

```json
{
  "mcpServers": {
    "unity-hub": {
      "command": "python3",
      "args": ["/Users/denis/dev/unity-mcp-launcher/hub_mcp_gateway/run.py"],
      "env": {
        "HUB_MCP_HUB_URL": "http://127.0.0.1:8787",
        "HUB_MCP_HUB_TOKEN": "dev-shared-secret",
        "HUB_MCP_CLIENT_ID": "denis-mac"
      }
    }
  }
}
```

### Typical tool sequence

1. `list_projects`
2. `select_project`
3. `list_unity_tools`
4. `call_unity_tool`
