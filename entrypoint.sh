#!/bin/sh
set -e

# Match container claude user to host user's uid/gid so file ownership is seamless
if [ -n "$HOST_UID" ] && [ "$HOST_UID" != "$(id -u claude)" ]; then
  usermod -u "$HOST_UID" claude
fi
if [ -n "$HOST_GID" ] && [ "$HOST_GID" != "$(getent group claude | cut -d: -f3)" ]; then
  groupmod -g "$HOST_GID" claude
fi

# Fix ownership of config volume (safety net for edge cases)
chown claude:claude /home/claude/.claude

# Ensure .claude.json exists in the volume with valid JSON if missing
if [ ! -s /home/claude/.claude/.claude.json ]; then
  echo '{}' > /home/claude/.claude/.claude.json
fi
chown claude:claude /home/claude/.claude/.claude.json

# Symlink so Claude finds it at ~/.claude.json
ln -sf /home/claude/.claude/.claude.json /home/claude/.claude.json

# Install project dependencies if --env was provided
if [ -n "$SANDBOX_ENV" ]; then
  ENV_FILE="/workspace/$SANDBOX_ENV"
  if [ ! -f "$ENV_FILE" ]; then
    echo "Error: $SANDBOX_ENV not found in project." >&2
    exit 1
  fi
  ENV_DIR="$(dirname "$ENV_FILE")"
  case "$SANDBOX_ENV" in
    */uv.lock|uv.lock)
      echo "Installing dependencies from $SANDBOX_ENV..."
      gosu claude uv sync --project "$ENV_DIR"
      ;;
    */requirements*.txt|requirements*.txt)
      echo "Installing dependencies from $SANDBOX_ENV..."
      gosu claude uv venv "$ENV_DIR/.venv"
      gosu claude uv pip install -q -r "$ENV_FILE"
      ;;
    */pyproject.toml|pyproject.toml)
      echo "Installing dependencies from $SANDBOX_ENV..."
      gosu claude uv sync --project "$ENV_DIR"
      ;;
    *)
      echo "Error: unsupported env file '$SANDBOX_ENV'. Use uv.lock, requirements.txt, or pyproject.toml." >&2
      exit 1
      ;;
  esac
fi

SANDBOX_PROMPT="You are running inside a Docker sandbox. \
You have passwordless sudo — use 'sudo apt-get update && sudo apt-get install -y <pkg>' for system packages. \
Pre-installed: build-essential, nodejs, npm, python3-dev, CUDA toolkit (nvcc), jq, ripgrep, wget, unzip, ffmpeg. \
ALWAYS use uv instead of pip or raw python: \
'uv add <pkg>', 'uv pip install <pkg>', 'uv run <script.py>'. \
Never use 'pip install' or 'python' directly."

# Tell the agent about the host filesystem if mounted
if [ -n "$HOST_HOME" ] && [ -d "$HOST_HOME" ]; then
  SANDBOX_PROMPT="${SANDBOX_PROMPT} \
The host user's home directory is mounted READ-ONLY at $HOST_HOME. \
You can read models, data, configs, and other files there, but you CANNOT write to it. \
Your writable workspace is /workspace — all output and code changes go there."
fi

if [ -z "$SANDBOX_ENV" ]; then
  SANDBOX_PROMPT="${SANDBOX_PROMPT} \
Dependencies have NOT been pre-installed. \
Do NOT run 'uv sync' or install dependencies unless the user explicitly asks. \
Use 'uv run --no-sync <script.py>' to avoid triggering automatic dependency installation."
fi

SANDBOX_PORT="${SANDBOX_PORT:-7681}"

if [ "$SANDBOX_MODE" = "web" ]; then
  echo "Starting web terminal on port $SANDBOX_PORT..."
  exec gosu claude ttyd \
    --writable \
    --port "$SANDBOX_PORT" \
    claude --dangerously-skip-permissions \
    --append-system-prompt "$SANDBOX_PROMPT" "$@"
else
  exec gosu claude claude --dangerously-skip-permissions \
    --append-system-prompt "$SANDBOX_PROMPT" "$@"
fi
