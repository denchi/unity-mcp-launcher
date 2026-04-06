SHELL := /bin/zsh

.PHONY: run run-hub run-hub-mcp build test-hub test-gateway-smoke ship-check package-macos

run:
	cd /Users/denis/dev/unity-mcp-launcher && swift run UnityMCPHubApp

run-hub:
	cd /Users/denis/dev/unity-mcp-launcher/hub_service && python3 run.py

run-hub-mcp:
	cd /Users/denis/dev/unity-mcp-launcher/hub_mcp_gateway && python3 run.py

build:
	swift build --package-path /Users/denis/dev/unity-mcp-launcher

test-hub:
	cd /Users/denis/dev/unity-mcp-launcher/hub_service && python3 -m unittest discover -s tests -p 'test_*.py'

test-gateway-smoke:
	cd /Users/denis/dev/unity-mcp-launcher/hub_mcp_gateway && PYTHONPYCACHEPREFIX=/tmp/.python-pycache python3 -m py_compile run.py server.py

ship-check: build test-hub test-gateway-smoke

package-macos:
	cd /Users/denis/dev/unity-mcp-launcher && ./package_macos_app.sh $(VERSION)
