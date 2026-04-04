#!/usr/bin/env bash
set -euo pipefail
trap 'echo "$0: line $LINENO: $BASH_COMMAND: exitcode $?"' ERR

# ABOUTME: Wrapper script to run Claude Code in Docker container
# ABOUTME: Handles project mounting and persistent Claude config

SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"

source "$SCRIPT_DIR/lib-common.sh"

# Parse command line arguments
DOCKER="${DOCKER:-docker}"
NO_CACHE=""
FORCE_REBUILD=false
MEMORY_LIMIT=""
CC_VERSION=""
SYNC_INTERVAL="5"
SESSION_ID=""
ARGS=()

while [[ $# -gt 0 ]]; do
    case $1 in
        --podman)
            DOCKER=podman
            shift
            ;;
        --no-cache)
            NO_CACHE="--no-cache"
            shift
            ;;
        --rebuild)
            FORCE_REBUILD=true
            shift
            ;;
        --continue)
            ARGS+=("--continue")
            shift
            ;;
        --skip-permissions)
            ARGS+=("--dangerously-skip-permissions")
            shift
            ;;
        --sync-interval)
            SYNC_INTERVAL="$2"
            shift 2
            ;;
        --memory)
            MEMORY_LIMIT="$2"
            shift 2
            ;;
        --cc-version)
            CC_VERSION="$2"
            shift 2
            ;;
        --session-id)
            SESSION_ID="$2"
            shift 2
            ;;
        *)
            ARGS+=("$1")
            shift
            ;;
    esac
done

# Validate runtime before any build/run operations.
check_container_runtime "$DOCKER" "1.44"

# Get the absolute path of the current directory
CURRENT_DIR=$(pwd)

# Claude config dir: use CLAUDE_CONFIG_DIR env var if set, otherwise default to ~/.claude-docker
CLAUDE_HOME_DIR="${CLAUDE_CONFIG_DIR:-${HOME}/.claude-docker}"

CLAUDE_CONFIG_DIR="$CLAUDE_HOME_DIR/claude-home"
mkdir -p "$CLAUDE_HOME_DIR" "$CLAUDE_CONFIG_DIR"

# Copy authentication files to persistent directory if they don't exist yet (one-time bootstrap)
if [ -f "$HOME/.claude/.credentials.json" ] && [ ! -f "$CLAUDE_CONFIG_DIR/.credentials.json" ]; then
    echo "✓ Copying Claude authentication to persistent directory"
    cp "$HOME/.claude/.credentials.json" "$CLAUDE_CONFIG_DIR/.credentials.json"
fi
if [ -f "$HOME/.claude.json" ] && [ ! -f "$CLAUDE_HOME_DIR/.claude.json" ]; then
    echo "✓ Copying .claude.json to persistent directory"
    cp "$HOME/.claude.json" "$CLAUDE_HOME_DIR/.claude.json"
fi
touch "$CLAUDE_HOME_DIR/.claude.json"

# Bootstrap settings.json from the repo if none exists in the persistent directory yet
if [ ! -f "$CLAUDE_CONFIG_DIR/settings.json" ] && [ -f "$PROJECT_ROOT/settings.json" ]; then
    echo "✓ Copying settings.json to persistent directory"
    cp "$PROJECT_ROOT/settings.json" "$CLAUDE_CONFIG_DIR/settings.json"
fi


# Derive a stable session UUID for this project if not explicitly provided.
# UUID is generated once (v4) and stored so it stays consistent across runs.
if [ -z "$SESSION_ID" ]; then
    _key=$(echo "$CURRENT_DIR" | md5sum | cut -c1-8)
    _uuid_dir="${CLAUDE_HOME_DIR}/session-uuids"
    mkdir -p "$_uuid_dir"
    _uuid_file="${_uuid_dir}/${_key}.uuid"
    if [ -f "$_uuid_file" ]; then
        SESSION_ID=$(cat "$_uuid_file")
    else
        SESSION_ID=$(uuidgen)
        echo "$SESSION_ID" > "$_uuid_file"
    fi
    unset _key _uuid_dir _uuid_file
fi

# Use environment variables as defaults if command line args not provided
if [ -z "${MEMORY_LIMIT:-}" ] && [ -n "${DOCKER_MEMORY_LIMIT:-}" ]; then
    MEMORY_LIMIT="$DOCKER_MEMORY_LIMIT"
    echo "✓ Using memory limit from environment: $MEMORY_LIMIT"
fi

# Check if we need to rebuild the image
NEED_REBUILD=false

if ! "$DOCKER" images | grep -q "claude-docker"; then
    echo "Building Claude Docker image for first time..."
    NEED_REBUILD=true
fi

if [ "$FORCE_REBUILD" = true ]; then
    echo "Forcing rebuild of Claude Docker image..."
    NEED_REBUILD=true
fi

# Warn if --no-cache is used without rebuild
if [ -n "${NO_CACHE:-}" ] && [ "$NEED_REBUILD" = false ]; then
    echo "⚠️  Warning: --no-cache flag set but image already exists. Use --rebuild --no-cache to force rebuild without cache."
fi

if [ "$NEED_REBUILD" = true ]; then
    BUILD_CMD=("$DOCKER" build)
    [ -n "$NO_CACHE" ] && BUILD_CMD+=("--no-cache")
    if [ -n "${SYSTEM_PACKAGES:-}" ]; then
        echo "✓ Building with additional system packages: $SYSTEM_PACKAGES"
        BUILD_CMD+=(--build-arg "SYSTEM_PACKAGES=$SYSTEM_PACKAGES")
    fi
    if [ -n "${CC_VERSION:-}" ]; then
        echo "✓ Building with Claude Code version: $CC_VERSION"
        BUILD_CMD+=(--build-arg "CC_VERSION=$CC_VERSION")
    fi
    BUILD_CMD+=(-t claude-docker:latest "$PROJECT_ROOT")
    "${BUILD_CMD[@]}"
fi

echo "✓ Claude persistent directory: $CLAUDE_HOME_DIR"

DOCKER_OPTS=""

# Add memory limit if specified
if [ -n "${MEMORY_LIMIT:-}" ]; then
    echo "✓ Setting memory limit: $MEMORY_LIMIT"
    DOCKER_OPTS="$DOCKER_OPTS --memory $MEMORY_LIMIT"
fi

# Enable host.docker.internal DNS so container can reach host services
DOCKER_OPTS="$DOCKER_OPTS --add-host=host.docker.internal:host-gateway"

# Build rsync exclude flag from .claudedockerignore
IGNORE_FILE="$CURRENT_DIR/.claudedockerignore"
RSYNC_EXCLUDES=""
if [ -f "$IGNORE_FILE" ]; then
    RSYNC_EXCLUDES="--exclude-from=/host-workspace/.claudedockerignore"
    echo "📋 Found .claudedockerignore - ignored paths will be excluded from sync"
else
    echo "No .claudedockerignore found - all files will be synced to container"
fi

# Unique names for this session
# PROJECT_KEY = basename + short hash of full path, stable across sessions for the same directory
PROJECT_NAME="$(basename "$CURRENT_DIR")"
PATH_HASH=$(echo "$CURRENT_DIR" | md5sum | cut -c1-8)
PROJECT_KEY="${PROJECT_NAME}-${PATH_HASH}"
DOCKER_SESSION_ID="$PROJECT_KEY-$$"
VOLUME_NAME="claude-workspace-$DOCKER_SESSION_ID"
SYNC_CONTAINER="claude-sync-$DOCKER_SESSION_ID"
CLAUDE_CONTAINER="claude-docker-$DOCKER_SESSION_ID"

# Clean up any leftover sync containers and volumes from crashed previous sessions
LEFTOVER_CONTAINERS=$("$DOCKER" ps -aq --filter "name=claude-sync-$PROJECT_KEY" 2>/dev/null)
if [ -n "$LEFTOVER_CONTAINERS" ]; then
    echo "Cleaning up leftover sync containers from previous session..."
    "$DOCKER" rm -f $LEFTOVER_CONTAINERS 2>/dev/null || true
fi
LEFTOVER_VOLUMES=$("$DOCKER" volume ls -q --filter "name=claude-workspace-$PROJECT_KEY" 2>/dev/null)
if [ -n "$LEFTOVER_VOLUMES" ]; then
    echo "Cleaning up leftover workspace volumes from previous session..."
    "$DOCKER" volume rm $LEFTOVER_VOLUMES 2>/dev/null || true
fi

# Cleanup: final sync, stop sidecar, remove volume
_cleanup() {
    echo ""
    echo "Performing final sync to host..."
    "$DOCKER" stop "$SYNC_CONTAINER" 2>/dev/null || true
    "$DOCKER" rm "$SYNC_CONTAINER" 2>/dev/null || true
    "$DOCKER" run --rm \
        --entrypoint rsync \
        -v "$CURRENT_DIR:/host-workspace" \
        -v "$VOLUME_NAME:/workspace:ro" \
        claude-docker:latest \
        -a --delete $RSYNC_EXCLUDES /workspace/ /host-workspace/ 2>/dev/null || true
    "$DOCKER" volume rm "$VOLUME_NAME" 2>/dev/null || true
}
trap '_cleanup' EXIT

# Create named volume for workspace (Claude never sees the host dir)
"$DOCKER" volume create "$VOLUME_NAME" > /dev/null

# Initial sync: host -> volume (excluding ignored paths)
echo "Syncing workspace into container..."
"$DOCKER" run --rm \
    --entrypoint rsync \
    -v "$CURRENT_DIR:/host-workspace:ro" \
    -v "$VOLUME_NAME:/workspace" \
    claude-docker:latest \
    -a $RSYNC_EXCLUDES /host-workspace/ /workspace/
echo "✓ Workspace ready"

# Start sidecar: bidirectional sync loop (host <-> volume)
SIDECAR_SCRIPT="while true; do
    sleep ${SYNC_INTERVAL};
    rsync -a --update $RSYNC_EXCLUDES /host-workspace/ /workspace/;
    rsync -a --delete $RSYNC_EXCLUDES /workspace/ /host-workspace/;
done"
"$DOCKER" run -d \
    --name "$SYNC_CONTAINER" \
    --entrypoint bash \
    -v "$CURRENT_DIR:/host-workspace" \
    -v "$VOLUME_NAME:/workspace" \
    claude-docker:latest \
    -c "$SIDECAR_SCRIPT" > /dev/null
echo "✓ Sync sidecar started (every ${SYNC_INTERVAL}s)"

# Run Claude Code in Docker (named volume only - host dir not mounted)
echo "Starting Claude Code in Docker..."
"$DOCKER" run -it --rm \
    $DOCKER_OPTS \
    -v "$VOLUME_NAME:/workspace" \
    -v "$CLAUDE_CONFIG_DIR:/home/claude-user/.claude:rw" \
    -v "$CLAUDE_HOME_DIR/.claude.json:/home/claude-user/.claude.json:rw" \
    -v "/etc/machine-id:/etc/machine-id:ro" \
    -e "CLAUDE_SESSION_ID=$SESSION_ID" \
    --workdir /workspace \
    --name "$CLAUDE_CONTAINER" \
    claude-docker:latest ${ARGS[@]+"${ARGS[@]}"}
