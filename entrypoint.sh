#!/bin/sh
set -e

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

SANDBOX_PROMPT="You are running inside a Docker container with uv pre-installed. \
ALWAYS use uv instead of pip or raw python: \
'uv add <pkg>' to add dependencies, \
'uv pip install <pkg>' to install packages, \
'uv run <script.py>' to run Python scripts. \
Never use 'pip install' or 'python' directly."

if [ -z "$SANDBOX_ENV" ]; then
  SANDBOX_PROMPT="${SANDBOX_PROMPT} \
Dependencies have NOT been pre-installed. \
Do NOT run 'uv sync' or install dependencies unless the user explicitly asks. \
Use 'uv run --no-sync <script.py>' to avoid triggering automatic dependency installation."
fi

exec gosu claude claude --dangerously-skip-permissions \
  --append-system-prompt "$SANDBOX_PROMPT" "$@"
