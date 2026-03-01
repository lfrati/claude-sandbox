FROM nvidia/cuda:13.1.1-devel-ubuntu24.04

RUN apt-get update && apt-get install -y --no-install-recommends \
    python3 python3-venv python3-dev curl git gosu sudo \
    build-essential pkg-config \
    libssl-dev libffi-dev zlib1g-dev \
    nodejs npm \
    jq ripgrep wget unzip ttyd ffmpeg \
    && rm -rf /var/lib/apt/lists/*

# Install uv (from official image, no shell pipe needed)
COPY --from=ghcr.io/astral-sh/uv:latest /uv /usr/local/bin/uv

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

WORKDIR /workspace
EXPOSE 7681

COPY --chmod=755 entrypoint.sh /entrypoint.sh
ENTRYPOINT ["/entrypoint.sh"]
