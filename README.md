# claude-sandbox

A Docker container for running [Claude Code](https://docs.anthropic.com/en/docs/claude-code) unsupervised with GPU access. Claude runs with `--dangerously-skip-permissions` inside the container so it can work autonomously, while your host system stays safe.

## Prerequisites

- Docker with [NVIDIA Container Toolkit](https://docs.nvidia.com/datacenter/cloud-native/container-toolkit/latest/install-guide.html)
- A Claude account (Pro/Team/Enterprise subscription)

## Setup

Build the image:

```bash
docker build -t claude-sandbox .
```

## Usage

Add this function to your `.zshrc` (or `.bashrc`):

```bash
claude-sandbox() {
  if ! git rev-parse --is-inside-work-tree &>/dev/null; then
    echo "Error: not inside a git repository." >&2
    return 1
  fi
  docker run --rm -it --gpus all \
    -v "$(git rev-parse --show-toplevel)":/workspace \
    -v claude-config:/home/claude/.claude \
    -v uv-cache:/uv-cache \
    claude-sandbox "$@"
}
```

Then `cd` into any git repo and run:

```bash
claude-sandbox
```

It will refuse to start outside a git repo. Arguments are forwarded to Claude:

```bash
claude-sandbox --model sonnet -p "refactor the auth module"
```

On the first run you'll need to log in with `/login`. Your credentials are stored in the `claude-config` Docker volume and persist across container restarts.

Changes Claude makes inside `/workspace` are written directly to your host filesystem via the bind mount. When the container exits, review with `git diff` and commit or discard.

## Automatic dependency installation

The entrypoint auto-detects and installs project dependencies before starting Claude:

- `uv.lock` — installed via `uv sync` (creates `.venv` in the project directory)
- `requirements.txt` — installed into `.venv` via `uv venv` + `uv pip install`
- `pyproject.toml` — installed via `uv sync` (creates `.venv` in the project directory)

A shared `uv-cache` Docker volume means packages are downloaded once and reused across all projects. For `uv.lock` projects, the `.venv` persists on the host between runs (make sure `.venv` is in your `.gitignore`).

## How it works

- **`Dockerfile`** — Ubuntu 24.04 with Python, [uv](https://docs.astral.sh/uv/), and Claude Code. No project-specific packages are baked in. A non-root `claude` user is created because `--dangerously-skip-permissions` refuses to run as root.
- **`entrypoint.sh`** — Auto-installs deps, creates the config symlink, and launches Claude. The `~/.claude.json` config file is symlinked into `~/.claude/` so a single Docker volume persists all state.
- **`claude-config` volume** — Stores Claude's authentication and config. Lives in Docker's own storage, separate from your host's `~/.claude/`.
- **`uv-cache` volume** — Shared package download cache across all projects.

## Managing volumes

```bash
# List volumes
docker volume ls

# Force re-login by deleting the config volume
docker volume rm claude-config

# Clear the package cache
docker volume rm uv-cache
```
