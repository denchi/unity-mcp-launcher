# Hub MCP Gateway

Unified MCP server surface for:

- Hub control-plane tools (`list_projects`, `select_project`, session control)
- Unity project tools routed through selected session (`focus_unity_window`, `list_unity_tools`, `call_unity_tool`)

## Install

```bash
cd /Users/denis/dev/unity-mcp-launcher/hub_mcp_gateway
python3 -m pip install -r requirements.txt
```

## Run (stdio transport, for MCP clients)

```bash
cd /Users/denis/dev/unity-mcp-launcher/hub_mcp_gateway
python3 run.py
```

Or:

```bash
cd /Users/denis/dev/unity-mcp-launcher
make run-hub-mcp
```

## Environment variables

- `HUB_MCP_HUB_URL` (default `http://127.0.0.1:8787`)
- `HUB_MCP_HUB_TOKEN` (optional; if unset, gateway reads `HUB_AUTH_TOKEN_FILE` or `~/.unity-mcp-hub/auth_token`)
- `HUB_AUTH_TOKEN_FILE` (optional token file path shared with hub service)
- `HUB_MCP_CLIENT_ID` (default hostname slug)
- `HUB_MCP_TIMEOUT_SECONDS` (default `20`)
- `HUB_MCP_DEFAULT_EXECUTE_METHOD` (optional fallback execute method)
- `HUB_MCP_TRANSPORT` (default `stdio`)

## Tool flow

1. `list_projects`
2. `select_project`
3. `focus_unity_window`
4. `list_unity_tools`
5. `call_unity_tool`

Unity tools use the currently selected active session unless `session_id` is passed explicitly.
