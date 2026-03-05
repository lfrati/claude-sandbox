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

Add this to your `.zshrc` (or `.bashrc`), adjusting the path to where you cloned this repo:

```bash
source ~/git/claude-sandbox/claude-sandbox.sh
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

Pass `--web` to start Claude as a web terminal using [ttyd](https://github.com/tsl0922/ttyd). The container runs detached and is exposed across your [Tailscale](https://tailscale.com/) tailnet via `tailscale serve` with automatic HTTPS. Any device on your tailnet can reach it at `https://<machine>.<tailnet>.ts.net`. A free local port is picked automatically.

```bash
claude-sandbox --web                    # web terminal on tailnet
claude-sandbox --web --env uv.lock     # combine with other flags
```

When the container exits (via `docker rm -f`), `tailscale serve` is automatically torn down by a background cleanup process.

Stop a running instance using the container ID printed at startup:

```bash
docker rm -f <container-id>
```

## Worktrees

Pass `--worktree <name>` to run Claude in an isolated git worktree. The worktree is created on the host at `<repo>/.worktrees/<name>/` and mounted into the container. When the container exits, your shell stays in the worktree so you can review and push.

```bash
claude-sandbox --worktree feature-auth           # new branch
claude-sandbox --worktree feature-auth --web     # worktree + web terminal
claude-sandbox --worktree existing-branch        # existing branch
```

After the container exits:

```bash
git diff                                          # review changes
git push origin feature-auth                      # push when ready
git worktree remove .worktrees/feature-auth       # clean up
```

Add `.worktrees/` to your `.gitignore`.

## Dependency installation

Pass `--env` with a path (relative to the repo root) to install dependencies before Claude starts:

| File | What happens |
|------|-------------|
| `uv.lock` | `uv sync` in the file's directory |
| `pyproject.toml` | `uv sync` in the file's directory |
| `requirements.txt` | `uv venv` + `uv pip install -r` in the file's directory |

A shared `uv-cache` Docker volume means packages are downloaded once and reused across all projects. For `uv.lock` projects, the `.venv` persists on the host between runs (make sure `.venv` is in your `.gitignore`).

## How it works

- **`Dockerfile`** — Based on `nvidia/cuda` (Ubuntu 24.04) with Python, [uv](https://docs.astral.sh/uv/), CUDA toolkit, and Claude Code. Common dev tools are pre-installed (build-essential, Node.js/npm, python3-dev, jq, ripgrep, wget, unzip, ffmpeg, xclip) along with [ttyd](https://github.com/tsl0922/ttyd) for web terminal mode. Includes `stop-sandbox` to terminate the container from inside. The `claude` user has passwordless `sudo` for installing anything else. A non-root `claude` user is created because `--dangerously-skip-permissions` refuses to run as root.
- **`claude-sandbox.sh`** — Shell function sourced from your `.zshrc`. Handles flag parsing, worktree creation, Docker container launch, Tailscale serve integration, and cleanup.
- **`$HOME:$HOME:ro` mount** — Your entire home directory is mounted read-only inside the container at the same path. The agent can read your models, data, virtualenvs, configs — anything. The `:ro` flag is kernel-enforced; even root inside the container cannot write through it. `~/.ssh` and `~/.config/gh` are hidden with empty tmpfs overlays so the agent cannot use your SSH keys or GitHub CLI credentials. `~/models` is mounted writable so the agent can download models. X11 display and auth are forwarded for clipboard image paste support.
- **`/workspace` mount** — The git repo (or worktree), mounted read-write. The only place the agent can make changes. With `--worktree`, the main repo's `.git` directory is also mounted writable so the agent can commit.
- **`entrypoint.sh`** — Sets git identity, installs deps (when `--env` is used), creates the config symlink, injects no-push safety rules via `--append-system-prompt`, and launches Claude. In web mode (`SANDBOX_MODE=web`), it starts a ttyd server that serves Claude's TUI over HTTP. The `~/.claude.json` config file is symlinked into `~/.claude/` so a single Docker volume persists all state.
- **`claude-config` volume** — Stores Claude's authentication and config. Lives in Docker's own storage, separate from your host's `~/.claude/`.
- **`uv-cache` volume** — Shared package download cache across all projects.

## Testing

Run the test suite to verify the sandbox isolation, GPU access, and tooling:

```bash
./test.sh
```

This builds the image and checks: host home is readable but not writable (even with sudo), workspace is writable, SSH keys are hidden and git push fails, GitHub CLI credentials are hidden, no-push rules are in the entrypoint, GPU/CUDA work, sudo works, uv/uvx, Claude Code, ttyd, and xclip are available, terminal env is forwarded, clipboard access works, `apt-get install` works, and the agent can commit inside a worktree.

## Managing volumes

```bash
# List volumes
docker volume ls

# Force re-login by deleting the config volume
docker volume rm claude-config

# Clear the package cache
docker volume rm uv-cache
```
