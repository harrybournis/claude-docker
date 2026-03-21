#!/usr/bin/env bash
set -euo pipefail

# MCP server installation script.
# Add or remove servers here. Servers requiring API keys should be guarded
# with [ -n "${VAR:-}" ] so the build succeeds without them.

# Serena - code navigation and editing toolkit
claude mcp add-json "serena" '{
  "command":"bash",
  "args":["-c","for p in $(which uvx 2>/dev/null) $HOME/.local/bin/uvx /usr/local/bin/uvx uvx; do [ -x \"$p\" ] && exec \"$p\" --from git+https://github.com/oraios/serena serena-agent; done; echo '\''uvx not found'\'' >&2; exit 1"],
  "env":{"PATH":"/usr/local/bin:/usr/bin:/bin:~/.local/bin"},
  "timeout": 60000
}'

# Grep - search GitHub code (no credentials needed)
claude mcp add -s user --transport http grep https://mcp.grep.app

# Context7 - up-to-date library documentation (requires CONTEXT7_API_KEY)
if [ -n "${CONTEXT7_API_KEY:-}" ]; then
    claude mcp add -s user --transport http context7 https://mcp.context7.com/mcp \
        --header "CONTEXT7_API_KEY: ${CONTEXT7_API_KEY}"
fi
