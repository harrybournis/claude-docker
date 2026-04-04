#!/usr/bin/env bash
set -euo pipefail

# MCP server installation script.
# Add or remove servers here. Servers requiring API keys should be guarded
# with [ -n "${VAR:-}" ] so the build succeeds without them.

# Serena - code navigation and editing toolkit
claude mcp add serena -- \
  uvx --from git+https://github.com/oraios/serena \
  serena start-mcp-server --context claude-code --project "$(pwd)"

claude plugin install ruby-lsp@claude-plugins-official

# Context7 - up-to-date library documentation (requires CONTEXT7_API_KEY)
if [ -n "${CONTEXT7_API_KEY:-}" ]; then
    claude mcp add -s user --transport http context7 https://mcp.context7.com/mcp \
        --header "CONTEXT7_API_KEY: ${CONTEXT7_API_KEY}"
fi
