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
GPU_ACCESS=""
CC_VERSION=""
SYNC_INTERVAL="5"
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
        --gpus)
            GPU_ACCESS="$2"
            shift 2
            ;;
        --cc-version)
            CC_VERSION="$2"
            shift 2
            ;;
        *)
            ARGS+=("$1")
            shift
            ;;
    esac
done

# Validate runtime and resolve persistent host directory before any build/run operations.
check_container_runtime "$DOCKER" "1.44"
resolve_claude_docker_dir

# Get the absolute path of the current directory
CURRENT_DIR=$(pwd)

CLAUDE_HOME_DIR="$CLAUDE_DOCKER_DIR/claude-home"
SSH_DIR="$CLAUDE_DOCKER_DIR/ssh"

# Use environment variables as defaults if command line args not provided
if [ -z "${MEMORY_LIMIT:-}" ] && [ -n "${DOCKER_MEMORY_LIMIT:-}" ]; then
    MEMORY_LIMIT="$DOCKER_MEMORY_LIMIT"
    echo "✓ Using memory limit from environment: $MEMORY_LIMIT"
fi

if [ -z "${GPU_ACCESS:-}" ] && [ -n "${DOCKER_GPU_ACCESS:-}" ]; then
    GPU_ACCESS="$DOCKER_GPU_ACCESS"
    echo "✓ Using GPU access from environment: $GPU_ACCESS"
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
    BUILD_CMD+=(--build-arg "USER_UID=$(id -u)" --build-arg "USER_GID=$(id -g)")
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

# Ensure the claude-home and ssh directories exist
mkdir -p "$CLAUDE_HOME_DIR"
mkdir -p "$SSH_DIR"

# Copy authentication files to persistent claude-home if they don't exist
if [ -n "${HOME:-}" ] && [ -f "$HOME/.claude/.credentials.json" ] && [ ! -f "$CLAUDE_HOME_DIR/.credentials.json" ]; then
    echo "✓ Copying Claude authentication to persistent directory"
    cp "$HOME/.claude/.credentials.json" "$CLAUDE_HOME_DIR/.credentials.json"
fi

# Log information about persistent Claude home directory
echo ""
echo "📁 Claude persistent home directory: $CLAUDE_HOME_DIR/"
echo "   This directory contains Claude's settings and CLAUDE.md instructions"
echo "   Modify files here to customize Claude's behavior across all projects"
echo ""

# Check SSH key setup
SSH_KEY_PATH="$SSH_DIR/id_rsa"
SSH_PUB_KEY_PATH="$SSH_DIR/id_rsa.pub"

if [ ! -f "$SSH_KEY_PATH" ] || [ ! -f "$SSH_PUB_KEY_PATH" ]; then
    echo ""
    echo "⚠️  SSH keys not found for git operations"
    echo "   To enable git push/pull in Claude Docker:"
    echo ""
    echo "   1. Generate SSH key:"
    echo "      ssh-keygen -t rsa -b 4096 -f $SSH_DIR/id_rsa -N ''"
    echo ""
    echo "   2. Add public key to GitHub:"
    echo "      cat $SSH_DIR/id_rsa.pub"
    echo "      # Copy output and add to: GitHub → Settings → SSH Keys"
    echo ""
    echo "   3. Test connection:"
    echo "      ssh -T git@github.com -i $SSH_DIR/id_rsa"
    echo ""
    echo "   Claude will continue without SSH keys (read-only git operations only)"
    echo ""
else
    echo "✓ SSH keys found for git operations"

    # Create SSH config if it doesn't exist
    SSH_CONFIG_PATH="$SSH_DIR/config"
    if [ ! -f "$SSH_CONFIG_PATH" ]; then
        cat > "$SSH_CONFIG_PATH" << 'EOF'
Host github.com
    HostName github.com
    User git
    IdentityFile ~/.ssh/id_rsa
    IdentitiesOnly yes
EOF
        echo "✓ SSH config created for GitHub"
    fi
fi

# Prepare additional mount arguments
MOUNT_ARGS=""
ENV_ARGS=""
DOCKER_OPTS=""

# Add memory limit if specified
if [ -n "${MEMORY_LIMIT:-}" ]; then
    echo "✓ Setting memory limit: $MEMORY_LIMIT"
    DOCKER_OPTS="$DOCKER_OPTS --memory $MEMORY_LIMIT"
fi

# Add GPU access if specified
if [ -n "${GPU_ACCESS:-}" ]; then
    # Check if nvidia-docker2 or nvidia-container-runtime is available
    if "$DOCKER" info 2>/dev/null | grep -q nvidia || which nvidia-docker >/dev/null 2>&1; then
        echo "✓ Enabling GPU access: $GPU_ACCESS"
        DOCKER_OPTS="$DOCKER_OPTS --gpus $GPU_ACCESS"
    else
        echo "⚠️  GPU access requested but NVIDIA Docker runtime not found"
        echo "   Install nvidia-docker2 or nvidia-container-runtime to enable GPU support"
        echo "   Continuing without GPU access..."
    fi
fi

# Enable host.docker.internal DNS so container can reach host services (e.g. vLLM on port 8000)
DOCKER_OPTS="$DOCKER_OPTS --add-host=host.docker.internal:host-gateway"

# Mount conda installation if specified
if [ -n "${CONDA_PREFIX:-}" ] && [ -d "$CONDA_PREFIX" ]; then
    echo "✓ Mounting conda installation from $CONDA_PREFIX"
    MOUNT_ARGS="$MOUNT_ARGS -v $CONDA_PREFIX:$CONDA_PREFIX:ro"
    ENV_ARGS="$ENV_ARGS -e CONDA_PREFIX=$CONDA_PREFIX -e CONDA_EXE=$CONDA_PREFIX/bin/conda"
else
    echo "No conda installation configured"
fi

# Mount additional conda directories if specified
if [ -n "${CONDA_EXTRA_DIRS:-}" ]; then
    echo "✓ Mounting additional conda directories..."
    CONDA_ENVS_PATHS=""
    CONDA_PKGS_PATHS=""
    for dir in $CONDA_EXTRA_DIRS; do
        if [ -d "$dir" ]; then
            echo "  - Mounting $dir"
            MOUNT_ARGS="$MOUNT_ARGS -v $dir:$dir:ro"
            # Build comma-separated list for CONDA_ENVS_DIRS
            if [[ "$dir" == *"env"* ]]; then
                if [ -z "${CONDA_ENVS_PATHS:-}" ]; then
                    CONDA_ENVS_PATHS="$dir"
                else
                    CONDA_ENVS_PATHS="$CONDA_ENVS_PATHS:$dir"
                fi
            fi
            # Build comma-separated list for CONDA_PKGS_DIRS
            if [[ "$dir" == *"pkg"* ]]; then
                if [ -z "${CONDA_PKGS_PATHS:-}" ]; then
                    CONDA_PKGS_PATHS="$dir"
                else
                    CONDA_PKGS_PATHS="$CONDA_PKGS_PATHS:$dir"
                fi
            fi
        else
            echo "  - Skipping $dir (not found)"
        fi
    done
    # Set CONDA_ENVS_DIRS environment variable if we found env paths
    if [ -n "${CONDA_ENVS_PATHS:-}" ]; then
        ENV_ARGS="$ENV_ARGS -e CONDA_ENVS_DIRS=$CONDA_ENVS_PATHS"
        echo "  - Setting CONDA_ENVS_DIRS=$CONDA_ENVS_PATHS"
    fi
    # Set CONDA_PKGS_DIRS environment variable if we found pkg paths
    if [ -n "${CONDA_PKGS_PATHS:-}" ]; then
        ENV_ARGS="$ENV_ARGS -e CONDA_PKGS_DIRS=$CONDA_PKGS_PATHS"
        echo "  - Setting CONDA_PKGS_DIRS=$CONDA_PKGS_PATHS"
    fi
else
    echo "No additional conda directories configured"
fi

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
SESSION_ID="$PROJECT_KEY-$$"
VOLUME_NAME="claude-workspace-$SESSION_ID"
SYNC_CONTAINER="claude-sync-$SESSION_ID"
CLAUDE_CONTAINER="claude-docker-$SESSION_ID"

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
    -v "$CLAUDE_HOME_DIR:/home/claude-user/.claude:rw" \
    -v "$SSH_DIR:/home/claude-user/.ssh:rw" \
    $MOUNT_ARGS \
    $ENV_ARGS \
    --workdir /workspace \
    --name "$CLAUDE_CONTAINER" \
    claude-docker:latest ${ARGS[@]+"${ARGS[@]}"}
