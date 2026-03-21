FROM nvidia/cuda:13.1.1-devel-ubuntu24.04

RUN apt-get update && apt-get install -y --no-install-recommends \
    python3 python3-venv python3-dev curl git gosu sudo \
    build-essential pkg-config \
    libssl-dev libffi-dev zlib1g-dev \
    nodejs npm \
    jq ripgrep wget unzip ffmpeg xclip \
    iptables ipset iproute2 dnsutils \
    && rm -rf /var/lib/apt/lists/*

# GitHub CLI (from official apt repo)
RUN curl -fsSL https://cli.github.com/packages/githubcli-archive-keyring.gpg \
      -o /usr/share/keyrings/githubcli-archive-keyring.gpg \
    && echo "deb [arch=$(dpkg --print-architecture) signed-by=/usr/share/keyrings/githubcli-archive-keyring.gpg] https://cli.github.com/packages stable main" \
      > /etc/apt/sources.list.d/github-cli.list \
    && apt-get update && apt-get install -y --no-install-recommends gh \
    && rm -rf /var/lib/apt/lists/*

# Install uv (from official image, no shell pipe needed)
COPY --from=ghcr.io/astral-sh/uv:latest /uv /usr/local/bin/uv
COPY --from=ghcr.io/astral-sh/uv:latest /uvx /usr/local/bin/uvx

# Non-root user at uid 1000 (matches typical host user, required for --dangerously-skip-permissions)
RUN if id ubuntu &>/dev/null; then \
      usermod -l claude -d /home/claude -m ubuntu && groupmod -n claude ubuntu; \
    else \
      groupadd -g 1000 claude && useradd -m -s /bin/bash -u 1000 -g claude claude; \
    fi && \
    echo 'claude ALL=(ALL) NOPASSWD:ALL' > /etc/sudoers.d/claude

# uv cache dir owned by claude (Docker copies ownership to new volumes)
RUN mkdir -p /uv-cache && chown claude /uv-cache
ENV UV_CACHE_DIR=/uv-cache

# Install Claude Code as the claude user
USER claude
ENV PATH="/home/claude/.local/bin:$PATH"
RUN curl -fsSL https://claude.ai/install.sh | bash

# Switch back to root so entrypoint can fix permissions before dropping privileges
USER root

RUN printf '#!/bin/sh\nkill 1\n' > /usr/local/bin/stop-sandbox && chmod +x /usr/local/bin/stop-sandbox

WORKDIR /workspace

COPY --chown=claude:claude settings.json /etc/claude-defaults/settings.json
COPY test-beep.wav /test-beep.wav

COPY --chmod=755 init-firewall.sh /usr/local/bin/init-firewall.sh
COPY --chmod=755 entrypoint.sh /entrypoint.sh
ENTRYPOINT ["/entrypoint.sh"]
