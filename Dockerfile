FROM ubuntu:24.04

RUN apt-get update && apt-get install -y --no-install-recommends \
    python3 python3-venv curl git gosu && \
    rm -rf /var/lib/apt/lists/*

# Install uv (from official image, no shell pipe needed)
COPY --from=ghcr.io/astral-sh/uv:latest /uv /usr/local/bin/uv

# Non-root user (required for --dangerously-skip-permissions)
# ubuntu:24.04 ships with user "ubuntu" at uid 1000
RUN usermod -l claude -d /home/claude -m ubuntu && groupmod -n claude ubuntu

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

COPY --chmod=755 entrypoint.sh /entrypoint.sh
ENTRYPOINT ["/entrypoint.sh"]
