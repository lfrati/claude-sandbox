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

# Auto-install project dependencies (as claude user)
if [ -f /workspace/uv.lock ]; then
  echo "Installing dependencies from uv.lock..."
  gosu claude uv sync --project /workspace
elif [ -f /workspace/requirements.txt ]; then
  echo "Installing dependencies from requirements.txt..."
  gosu claude uv venv /workspace/.venv
  gosu claude uv pip install -q -r /workspace/requirements.txt
elif [ -f /workspace/pyproject.toml ]; then
  echo "Installing dependencies from pyproject.toml..."
  gosu claude uv sync --project /workspace
fi

SANDBOX_PROMPT="You are running inside a Docker container with uv pre-installed. \
ALWAYS use uv instead of pip or raw python: \
'uv add <pkg>' to add dependencies, \
'uv pip install <pkg>' to install packages, \
'uv run <script.py>' to run Python scripts. \
Never use 'pip install' or 'python' directly."

exec gosu claude claude --dangerously-skip-permissions \
  --append-system-prompt "$SANDBOX_PROMPT" "$@"
