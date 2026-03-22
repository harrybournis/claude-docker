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
CLAUDE_ARGS=()
[ -n "${CLAUDE_SESSION_ID:-}" ] && CLAUDE_ARGS+=("--session-id" "${CLAUDE_SESSION_ID}")
[ -n "${CLAUDE_CONTINUE_FLAG:-}" ] && CLAUDE_ARGS+=("${CLAUDE_CONTINUE_FLAG}")
[ "${CLAUDE_DANGEROUSLY_SKIP_PERMISSIONS:-false}" = "true" ] && CLAUDE_ARGS+=("--dangerously-skip-permissions")

if claude "${CLAUDE_ARGS[@]}" "$@"; then
    exit 0
fi

# If --continue was passed but no session exists, retry without it
if [[ " ${CLAUDE_ARGS[*]:-} $* " == *"--continue"* ]]; then
    echo "No previous session found, starting fresh..."
    CLAUDE_ARGS=("${CLAUDE_ARGS[@]/--continue}")
    ARGS_NO_CONTINUE=()
    for arg in "$@"; do
        [ "$arg" != "--continue" ] && ARGS_NO_CONTINUE+=("$arg")
    done
    exec claude "${CLAUDE_ARGS[@]}" "${ARGS_NO_CONTINUE[@]+"${ARGS_NO_CONTINUE[@]}"}"
fi

exit 1
