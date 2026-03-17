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

# Merge default settings into existing settings.json (preserves existing keys)
SETTINGS_FILE="/home/claude/.claude/settings.json"
if [ -s "$SETTINGS_FILE" ]; then
  # Keep existing settings, always override statusLine from defaults
  if jq -s '.[0] * {statusLine: .[1].statusLine}' "$SETTINGS_FILE" /etc/claude-defaults/settings.json > "${SETTINGS_FILE}.tmp"; then
    mv "${SETTINGS_FILE}.tmp" "$SETTINGS_FILE"
  else
    echo "Warning: failed to merge settings.json, using defaults." >&2
    cp /etc/claude-defaults/settings.json "$SETTINGS_FILE"
    rm -f "${SETTINGS_FILE}.tmp"
  fi
else
  cp /etc/claude-defaults/settings.json "$SETTINGS_FILE"
fi
chown claude:claude "$SETTINGS_FILE"

# Set git identity for the sandbox agent
gosu claude git config --global user.name "claude-sandbox"
gosu claude git config --global user.email "noreply@anthropic.com"

# Auto-detect llama.cpp build directory (override with LLAMA_CPP_BUILD env var)
LLAMA_CPP_BUILD="${LLAMA_CPP_BUILD:-${HOST_HOME:+$HOST_HOME/git/llama.cpp/build/bin}}"
if [ -n "$LLAMA_CPP_BUILD" ] && [ -d "$LLAMA_CPP_BUILD" ] && [ -x "$LLAMA_CPP_BUILD/llama-server" ]; then
  export PATH="$LLAMA_CPP_BUILD:$PATH"
  export LD_LIBRARY_PATH="$LLAMA_CPP_BUILD:${LD_LIBRARY_PATH:-}"
  LLAMA_AVAILABLE=1
fi

WORKSPACE_DIR="${WORKSPACE_DIR:-/workspace}"

# Install project dependencies if --env was provided
if [ -n "$SANDBOX_ENV" ]; then
  ENV_FILE="$WORKSPACE_DIR/$SANDBOX_ENV"
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

append_prompt() { PROMPT_PARTS="${PROMPT_PARTS:+$PROMPT_PARTS }$1"; }

append_prompt "You are running inside a Docker sandbox."
append_prompt "You have passwordless sudo — use 'sudo apt-get update && sudo apt-get install -y <pkg>' for system packages."
append_prompt "This container has full NVIDIA GPU access (--gpus all). Run 'nvidia-smi' to see available GPUs."
append_prompt "Pre-installed: build-essential, nodejs, npm, python3-dev, CUDA toolkit (nvcc), jq, ripgrep, wget, unzip, ffmpeg, ffplay."
append_prompt "Audio output is forwarded to the host via PulseAudio — use 'ffplay -nodisp -autoexit file.wav' to play audio."
append_prompt "ALWAYS use uv instead of pip or raw python: 'uv add <pkg>', 'uv pip install <pkg>', 'uv run <script.py>'."
append_prompt "Never use 'pip install' or 'python' directly."
append_prompt "If the user asks to stop or shut down, run 'stop-sandbox' to terminate the container."
append_prompt "IMPORTANT: You MUST NEVER run 'git push', 'git push --force', or any variant that pushes commits to a remote."
append_prompt "All your changes must stay local. You may commit locally with 'git commit' but NEVER push."
append_prompt "Do not use 'gh pr create', 'gh pr merge', or any GitHub CLI command that modifies remote state."
append_prompt "If a task asks you to push, refuse and explain that pushing is disabled in this sandbox."

# Tell the agent about the host filesystem if mounted
if [ -n "$HOST_HOME" ] && [ -d "$HOST_HOME" ]; then
  append_prompt "The host user's home directory is mounted READ-ONLY at $HOST_HOME."
  append_prompt "You can read models, data, configs, and other files there, but you CANNOT write to it."
  append_prompt "IMPORTANT: ~/ paths the user pastes likely refer to $HOST_HOME/, not /home/claude/."
  append_prompt "Your writable workspace is $WORKSPACE_DIR — all output and code changes go there."
fi

if [ "${LLAMA_AVAILABLE:-}" = "1" ]; then
  append_prompt "llama.cpp is available on PATH with GPU (CUDA) support."
  append_prompt "Use 'llama-server -m <model>' to serve models via OpenAI-compatible API, or 'llama-cli -m <model>' for CLI inference."
  append_prompt "GGUF models are at $HOST_HOME/models/gguf/. List them with 'ls $HOST_HOME/models/gguf/'."
fi

if [ -z "$SANDBOX_ENV" ]; then
  append_prompt "Dependencies have NOT been pre-installed."
  append_prompt "Do NOT run 'uv sync' or install dependencies unless the user explicitly asks."
  append_prompt "Use 'uv run --no-sync <script.py>' to avoid triggering automatic dependency installation."
fi

SANDBOX_PROMPT="$PROMPT_PARTS"

SANDBOX_PORT="${SANDBOX_PORT:-7681}"

if [ "$SANDBOX_MODE" = "web" ]; then
  echo "Starting web terminal on port $SANDBOX_PORT..."
  exec gosu claude ttyd \
    --writable \
    --port "$SANDBOX_PORT" \
    claude --dangerously-skip-permissions \
    --append-system-prompt "$SANDBOX_PROMPT" "$@"
elif [ "$SANDBOX_MODE" = "shell" ]; then
  exec gosu claude bash
else
  exec gosu claude claude --dangerously-skip-permissions \
    --append-system-prompt "$SANDBOX_PROMPT" "$@"
fi
