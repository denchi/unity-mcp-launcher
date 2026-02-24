from __future__ import annotations

import os

from server import mcp


def main() -> None:
    transport = os.getenv("HUB_MCP_TRANSPORT", "stdio").strip() or "stdio"
    mcp.run(transport=transport)


if __name__ == "__main__":
    main()

