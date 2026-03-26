# ABOUTME: Docker image for Claude Code
# ABOUTME: Provides autonomous Claude Code environment

FROM node:20-slim

ARG TZ
ENV TZ="${TZ:-UTC}"

# Remove default node user — we may need its UID for host matching
RUN deluser node 2>/dev/null || true && \
    delgroup node 2>/dev/null || true

# Install system dependencies (layer changes rarely)
RUN apt-get update && apt-get install -y --no-install-recommends \
    git \
    curl \
    wget \
    python3 \
    python3-pip \
    build-essential \
    sudo \
    gettext-base \
    rsync \
    jq \
    less \
    procps \
    unzip \
    && apt-get clean && rm -rf /var/lib/apt/lists/*

# Install optional additional system packages
ARG SYSTEM_PACKAGES=""
RUN if [ -n "$SYSTEM_PACKAGES" ]; then \
        apt-get update && \
        apt-get install -y --no-install-recommends $SYSTEM_PACKAGES && \
        apt-get clean && rm -rf /var/lib/apt/lists/*; \
    fi

# Create non-root user matching host UID/GID/username so HOME paths align
ARG USER_UID=1000
ARG USER_GID=1000
ARG USER_NAME=claude-user
RUN if getent group $USER_GID > /dev/null 2>&1; then \
        GROUP_NAME=$(getent group $USER_GID | cut -d: -f1); \
    else \
        groupadd -g $USER_GID $USER_NAME && GROUP_NAME=$USER_NAME; \
    fi && \
    useradd -m -s /bin/bash -u $USER_UID -g $GROUP_NAME $USER_NAME && \
    echo "$USER_NAME ALL=(ALL) NOPASSWD:ALL" >> /etc/sudoers

# Allow user to install npm packages globally without sudo
RUN mkdir -p /usr/local/share/npm-global && \
    chown -R ${USER_NAME} /usr/local/share/npm-global

# Pre-create shared directories with correct ownership
RUN mkdir -p /workspace /app && \
    chown -R ${USER_NAME} /app /workspace

# Persist bash history across container restarts
RUN mkdir -p /commandhistory && \
    touch /commandhistory/.bash_history && \
    chown -R ${USER_NAME} /commandhistory

# Switch to non-root user for all subsequent steps
USER ${USER_NAME}
ENV HOME=/home/${USER_NAME}
ENV PATH="/home/${USER_NAME}/.local/bin:/usr/local/share/npm-global/bin:${PATH}"
ENV NPM_CONFIG_PREFIX=/usr/local/share/npm-global
ENV PROMPT_COMMAND="history -a"
ENV HISTFILE=/commandhistory/.bash_history

# Install uv (Astral) for Serena MCP
RUN curl -LsSf https://astral.sh/uv/install.sh | sh

# Install Claude Code via native installer (npm install is deprecated upstream)
# Native binary bundles its own Node runtime — Node.js here is for MCP servers only
# Declare ARG late so version changes only bust this layer and below
ARG CC_VERSION=""
RUN if [ -n "$CC_VERSION" ]; then \
        curl -fsSL https://claude.ai/install.sh | bash -s "$CC_VERSION"; \
    else \
        curl -fsSL https://claude.ai/install.sh | bash; \
    fi

# Disable auto-updater — image is immutable, updates happen via rebuild
ENV DISABLE_AUTOUPDATER=1

# Install MCP servers after Claude Code — mcp-servers.sh uses the claude command
COPY --chown=${USER_NAME} mcp-servers.sh /app/mcp-servers.sh
RUN chmod +x /app/mcp-servers.sh && /app/mcp-servers.sh

# Copy startup script last — most likely to change during development
COPY --chown=${USER_NAME} src/startup.sh /app/startup.sh
RUN chmod +x /app/startup.sh

WORKDIR /workspace
ENV NODE_ENV=production
ENTRYPOINT ["/app/startup.sh"]
