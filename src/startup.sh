#!/usr/bin/env bash
set -uo pipefail

# ABOUTME: Startup script for claude-docker container
# ABOUTME: Checks for .credentials.json, copies CLAUDE.md template if no claude.md in claude-docker/claude-home.
# ABOUTME: Starts claude code with permissions bypass and continues from last session.
# NOTE: Need to call claude-docker --rebuild to integrate changes.

# Check for existing authentication
if [ -f "$HOME/.claude/.credentials.json" ]; then
    echo "Found existing Claude authentication"
else
    echo "No existing authentication found - you will need to log in"
    echo "Your login will be saved for future sessions"
fi

# Handle CLAUDE.md template
if [ ! -f "$HOME/.claude/CLAUDE.md" ]; then
    echo "✓ No CLAUDE.md found at $HOME/.claude/CLAUDE.md - copying template"
    # Copy from the template that was baked into the image
    if [ -f "/app/.claude/CLAUDE.md" ]; then
        cp "/app/.claude/CLAUDE.md" "$HOME/.claude/CLAUDE.md"
    fi
    echo "  Template copied to: $HOME/.claude/CLAUDE.md"
else
    echo "✓ Using existing CLAUDE.md from $HOME/.claude/CLAUDE.md"
    echo "  This maps to your host persistent claude-home/CLAUDE.md"
    echo "  Default host path: ~/.claude-docker/claude-home/CLAUDE.md"
    echo "  To reset to template, delete this file and restart"
fi

# Start Claude Code
echo "Starting Claude Code..."

# Separate --continue/-c from other passthrough args.
# When a session ID is available, --continue becomes --resume <id> so that
# the session is scoped to this project rather than the most recent global one.
CLAUDE_ARGS=()
PASSTHROUGH_ARGS=()
WANTS_CONTINUE=false
for arg in "$@"; do
    if [ "$arg" = "--continue" ] || [ "$arg" = "-c" ]; then
        WANTS_CONTINUE=true
    else
        PASSTHROUGH_ARGS+=("$arg")
    fi
done

if [ "$WANTS_CONTINUE" = true ] && [ -n "${CLAUDE_SESSION_ID:-}" ]; then
    CLAUDE_ARGS+=("--resume" "${CLAUDE_SESSION_ID}")
elif [ "$WANTS_CONTINUE" = true ]; then
    CLAUDE_ARGS+=("--continue")
elif [ -n "${CLAUDE_SESSION_ID:-}" ]; then
    CLAUDE_ARGS+=("--session-id" "${CLAUDE_SESSION_ID}")
fi

[ "${CLAUDE_DANGEROUSLY_SKIP_PERMISSIONS:-false}" = "true" ] && CLAUDE_ARGS+=("--dangerously-skip-permissions")

if claude "${CLAUDE_ARGS[@]}" "${PASSTHROUGH_ARGS[@]+"${PASSTHROUGH_ARGS[@]}"}"; then
    exit 0
fi

# If --resume found no session, retry fresh with just the session-id so it gets created
if [ "$WANTS_CONTINUE" = true ] && [ -n "${CLAUDE_SESSION_ID:-}" ]; then
    echo "No previous session found, starting fresh..."
    exec claude "--session-id" "${CLAUDE_SESSION_ID}" "${PASSTHROUGH_ARGS[@]+"${PASSTHROUGH_ARGS[@]}"}"
fi

exit 1
