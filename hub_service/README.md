# Unity MCP Hub Service

FastAPI + SQLite control-plane backend for Unity MCP orchestration.

## What it does

- Keeps a persistent project registry
- Creates client sessions bound to one project
- Launches Unity projects on demand
- Accepts agent registration + heartbeat
- Proxies calls from clients to selected agent endpoint

## Quick start

```bash
cd /Users/denis/dev/unity-mcp-launcher/hub_service
python3 -m pip install -r requirements.txt
python3 run.py
```

Server defaults:

- Host: `127.0.0.1`
- Port: `8787`
- Auth token: `dev-shared-secret`
- SQLite DB: `./hub_service/hub.db`

Optional integration env vars:

- `HUB_AGENT_HUB_URL` (what Unity agents should call back to; default `http://127.0.0.1:<port>`)
- `HUB_DEFAULT_EXECUTE_METHOD` (optional Unity `-executeMethod` value)
  - For ChatGptAssistant use: `Mcp.HubBootstrap.Start`
- `HUB_AGENT_HEARTBEAT_SECONDS` (default `10`)
- `HUB_UNITY_AGENT_PACKAGE_NAME` (defaults to `com.deathbygravitystudio.gptactions`)
- `HUB_UNITY_AGENT_PACKAGE_GIT_URL` (defaults to `https://github.com/denchi/UnityGPTActions.git#feature/mcp`)

Before launch, the hub patches `<project>/Packages/manifest.json` to enforce this dependency mapping:

- If the package name has the exact Git URL, no change is made.
- If missing, the dependency is added.
- If package name exists with a different value, it is updated.
- If manifest is missing/invalid, launch fails with a clear error.

## Auth

Use header `X-Hub-Token: <token>` on all control endpoints.

## Session lifecycle

1. Register/list projects.
2. Client calls `POST /sessions/select`.
3. Hub returns `session_id` + `launch_token` (inside session record).
4. Agent launches and calls `POST /agents/register` with `session_id` + `launch_token`.
5. Agent heartbeats with `session_id` + `agent_token`.
6. Client calls `POST /sessions/{session_id}/forward` to proxy MCP calls.

When the hub launches Unity from `POST /sessions/select`, it injects:

- `UNITY_MCP_HUB_URL`
- `UNITY_MCP_HUB_TOKEN`
- `UNITY_MCP_SESSION_ID`
- `UNITY_MCP_LAUNCH_TOKEN`
- `UNITY_MCP_HEARTBEAT_SECONDS`

`/sessions/{session_id}/forward` supports:

- `target: "agent"` (default) -> forwards to registered `endpoint`
- `target: "bridge"` -> forwards to `tool_manifest.bridge_url`

## Test repository logic

```bash
cd /Users/denis/dev/unity-mcp-launcher/hub_service
python3 -m unittest discover -s tests -p 'test_*.py'
```
