# claude-sandbox

A Docker container for running [Claude Code](https://docs.anthropic.com/en/docs/claude-code) unsupervised with GPU access. Claude runs with `--dangerously-skip-permissions` inside the container so it can work autonomously, while your host system stays safe.

Your entire home directory is mounted **read-only** so the agent can access models, data, configs, and anything else you have — but can only write to the project directory. The container also comes with common dev tools, CUDA, and passwordless `sudo` for installing anything else on the fly.

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
  local web="" port=7681
  local env_flag=()
  local args=()
  while [ $# -gt 0 ]; do
    case "$1" in
      --web)  web=1
              if [ -n "$2" ] && case "$2" in -*) false;; *) true;; esac; then
                port="$2"; shift
              fi
              shift ;;
      --env)  env_flag=(-e "SANDBOX_ENV=$2"); shift 2 ;;
      *)      args+=("$1"); shift ;;
    esac
  done
  local flags=(--gpus all
    -v "$HOME:$HOME:ro"
    --tmpfs "$HOME/.ssh:ro,size=0"
    --tmpfs "$HOME/.config/gh:ro,size=0"
    -v "$(git rev-parse --show-toplevel)":/workspace
    -v claude-config:/home/claude/.claude
    -v uv-cache:/uv-cache
    -e "HOST_HOME=$HOME"
    -e "HOST_UID=$(id -u)"
    -e "HOST_GID=$(id -g)"
    "${env_flag[@]}")
  if [ -n "$web" ]; then
    local cid
    cid=$(docker run -d \
      -e "SANDBOX_MODE=web" -e "SANDBOX_PORT=$port" -p "127.0.0.1:$port:$port" \
      "${flags[@]}" claude-sandbox "${args[@]}")
    echo "Container: ${cid:0:12}"
    tailscale serve --bg "http://127.0.0.1:$port"
    echo ""
    tailscale serve status
    echo ""
    echo "Stop: docker rm -f ${cid:0:12}"
    # When the container exits, tear down tailscale serve
    { docker wait "$cid" >/dev/null 2>&1
      tailscale serve --https=443 off
      echo "Tailscale serve stopped."
    } &!
  else
    docker run --rm -it "${flags[@]}" claude-sandbox "${args[@]}"
  fi
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

Use `--env` to install project dependencies before Claude starts:

```bash
claude-sandbox --env uv.lock
claude-sandbox --env requirements.txt
claude-sandbox --env lib/requirements-dev.txt
```

On the first run you'll need to log in with `/login`. Your credentials are stored in the `claude-config` Docker volume and persist across container restarts.

Changes Claude makes inside `/workspace` are written directly to your host filesystem via the bind mount. When the container exits, review with `git diff` and commit or discard.

## Web terminal mode

Pass `--web [port]` to start Claude as a web terminal using [ttyd](https://github.com/tsl0922/ttyd). The container runs detached and is exposed across your [Tailscale](https://tailscale.com/) tailnet via `tailscale serve` with automatic HTTPS. Any device on your tailnet can reach it at `https://<machine>.<tailnet>.ts.net`.

```bash
claude-sandbox --web                    # default port 7681
claude-sandbox --web 9090              # custom port
claude-sandbox --web --env uv.lock     # combine with other flags
```

When the container exits (via `docker rm -f`), `tailscale serve` is automatically torn down by a background cleanup process.

Stop a running instance using the container ID printed at startup:

```bash
docker rm -f <container-id>
```

## Dependency installation

Pass `--env` with a path (relative to the repo root) to install dependencies before Claude starts:

| File | What happens |
|------|-------------|
| `uv.lock` | `uv sync` in the file's directory |
| `pyproject.toml` | `uv sync` in the file's directory |
| `requirements.txt` | `uv venv` + `uv pip install -r` in the file's directory |

A shared `uv-cache` Docker volume means packages are downloaded once and reused across all projects. For `uv.lock` projects, the `.venv` persists on the host between runs (make sure `.venv` is in your `.gitignore`).

## How it works

- **`Dockerfile`** — Based on `nvidia/cuda` (Ubuntu 24.04) with Python, [uv](https://docs.astral.sh/uv/), CUDA toolkit, and Claude Code. Common dev tools are pre-installed (build-essential, Node.js/npm, python3-dev, jq, ripgrep, wget, unzip, ffmpeg) along with [ttyd](https://github.com/tsl0922/ttyd) for web terminal mode. The `claude` user has passwordless `sudo` for installing anything else. A non-root `claude` user is created because `--dangerously-skip-permissions` refuses to run as root.
- **`$HOME:$HOME:ro` mount** — Your entire home directory is mounted read-only inside the container at the same path. The agent can read your models, data, virtualenvs, configs — anything. The `:ro` flag is kernel-enforced; even root inside the container cannot write through it. `~/.ssh` and `~/.config/gh` are hidden with empty tmpfs overlays so the agent cannot use your SSH keys or GitHub CLI credentials.
- **`/workspace` mount** — The git repo, mounted read-write. The only place the agent can make changes.
- **`entrypoint.sh`** — Installs deps (when `--env` is used), creates the config symlink, and launches Claude. In web mode (`SANDBOX_MODE=web`), it starts a ttyd server that serves Claude's TUI over HTTP. The `~/.claude.json` config file is symlinked into `~/.claude/` so a single Docker volume persists all state.
- **`claude-config` volume** — Stores Claude's authentication and config. Lives in Docker's own storage, separate from your host's `~/.claude/`.
- **`uv-cache` volume** — Shared package download cache across all projects.

## Testing

Run the test suite to verify the sandbox isolation, GPU access, and tooling:

```bash
./test.sh
```

This builds the image and checks: host home is readable but not writable (even with sudo), workspace is writable, SSH keys are hidden and git push fails, GitHub CLI credentials are hidden, CLAUDE.md is present, GPU/CUDA work, sudo works, uv, Claude Code, and ttyd are available, and `apt-get install` works inside the container.

## Managing volumes

```bash
# List volumes
docker volume ls

# Force re-login by deleting the config volume
docker volume rm claude-config

# Clear the package cache
docker volume rm uv-cache
```
