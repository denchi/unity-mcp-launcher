.PHONY: run run-hub run-hub-mcp test-hub build

run:
	cd /Users/denis/dev/unity-mcp-launcher && swift run UnityMCPHubApp

run-hub:
	cd /Users/denis/dev/unity-mcp-launcher/hub_service && python3 run.py

run-hub-mcp:
	cd /Users/denis/dev/unity-mcp-launcher/hub_mcp_gateway && python3 run.py

build:
	cd /Users/denis/dev/unity-mcp-launcher && swift build

test-hub:
	cd /Users/denis/dev/unity-mcp-launcher/hub_service && python3 -m unittest discover -s tests -p 'test_*.py'
