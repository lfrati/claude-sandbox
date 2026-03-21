<p align="center">
  <img src="sandbox.png" width="256" alt="claude-sandbox">
</p>

# claude-sandbox

A Docker container for running [Claude Code](https://docs.anthropic.com/en/docs/claude-code) unsupervised with GPU access. Claude runs with `--dangerously-skip-permissions` inside the container so it can work autonomously, while your host system stays safe.

### Features

- **Full NVIDIA GPU access** — CUDA toolkit, nvcc, `--gpus all`
- **Network firewall** — iptables/ipset allowlist blocks all outbound traffic except essential domains (GitHub, Anthropic, PyPI, npm, apt, HuggingFace)
- **Capability drop** — NET_ADMIN/NET_RAW removed from bounding set after firewall setup; even `sudo su` can't disable the firewall
- **IPv6 blocked** — ip6tables DROP policy prevents IPv6 firewall bypass
- **Read-only home mount** — entire `$HOME` mounted `:ro` (kernel-enforced); agent can read models, data, configs but can't modify anything
- **Credential isolation** — `~/.ssh` and `~/.config/gh` hidden with empty tmpfs overlays; SSH keys and GitHub CLI credentials are inaccessible
- **Read-only GitHub access** — optional `SANDBOX_GH_TOKEN` for `gh` CLI read access (PRs, issues, code) without write permissions
- **UID/GID matching** — container user remapped to host uid/gid so file ownership is seamless
- **Worktree isolation** — `--worktree <name>` runs each agent on its own branch without conflicts
- **Dependency pre-installation** — `--env uv.lock` / `requirements.txt` / `pyproject.toml` installs before Claude starts
- **Shared package cache** — `uv-cache` Docker volume shared across all projects
- **llama.cpp auto-detection** — if built on the host, automatically added to PATH with CUDA support
- **Audio playback** — PulseAudio socket forwarded from host; `ffplay file.wav` plays through host speakers
- **Clipboard access** — X11 display and auth forwarded for xclip/image paste support
- **Pre-installed dev tools** — build-essential, Node.js/npm, python3-dev, jq, ripgrep, wget, unzip, ffmpeg, gh CLI, uv/uvx
- **Passwordless sudo** — `apt-get install`, `nsys`, `ncu`, etc. work without prompts
- **Shell mode** — `--shell` drops into bash for debugging with full privileges
- **System prompt injection** — sandbox rules (no-push, firewall info, available tools) injected via `--append-system-prompt`
- **Status line** — shows `user@host:dir [model · ctx: XX%]` in Claude's TUI
- **Persistent auth** — `claude-config` Docker volume persists login across container restarts
- **Named containers** — `<folder>-<random>` or `<branch>-<random>` for easy identification with `docker ps`
- **Comprehensive test suite** — `test.sh` validates isolation, security, GPU, tooling, and firewall

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

Containers are named `<folder>-<random>` (e.g. `my-project-3847`), so you can easily identify them with `docker ps` when running multiple sandboxes. With `--worktree`, the branch name is used instead of the folder name.

## Network firewall

A network firewall (iptables + ipset) is always active inside the container. It allowlists only the domains the agent needs and blocks everything else:

| Category | Domains |
|----------|---------|
| Claude Code | `api.anthropic.com`, `claude.ai`, `sentry.io`, `statsig.anthropic.com` |
| Python packages | `pypi.org`, `files.pythonhosted.org` |
| npm | `registry.npmjs.org` |
| Ubuntu apt | `archive.ubuntu.com`, `security.ubuntu.com` |
| AI/ML | `huggingface.co`, `cdn-lfs.hf.co`, `cdn-lfs-us-1.hf.co` |
| GitHub | All IPs from `api.github.com/meta` |

All other outbound traffic is rejected. This prevents the agent from exfiltrating code, contacting arbitrary APIs, or downloading unauthorized binaries — even with `sudo`. Edit `init-firewall.sh` to customize the allowlist.

## Read-only GitHub access

Set `SANDBOX_GH_TOKEN` to a [fine-grained GitHub PAT](https://github.com/settings/personal-access-tokens) with read-only permissions to give the agent `gh` CLI access for reading PRs, issues, and code without being able to modify anything:

```bash
export SANDBOX_GH_TOKEN=github_pat_...   # add to .zshrc
```

Create the token with these read-only permissions: **Contents**, **Issues**, **Pull requests**, **Metadata**. No write permissions. The token is passed as `GH_TOKEN` inside the container; the host's `~/.config/gh` credentials are always hidden via tmpfs overlay regardless.

## Worktrees

Pass `--worktree <name>` to run Claude in an isolated git worktree. The worktree is created on the host at `<repo>/.worktrees/<name>/` and mounted into the container. When the container exits, your shell stays in the worktree so you can review and push.

```bash
claude-sandbox --worktree feature-auth           # new branch
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

- **`Dockerfile`** — Based on `nvidia/cuda` (Ubuntu 24.04) with Python, [uv](https://docs.astral.sh/uv/), CUDA toolkit, GitHub CLI, and Claude Code. Common dev tools are pre-installed (build-essential, Node.js/npm, python3-dev, jq, ripgrep, wget, unzip, ffmpeg, xclip). Firewall tools (iptables, ipset, dnsutils) are included for the network allowlist. Includes `stop-sandbox` to terminate the container from inside. The `claude` user has passwordless `sudo` for installing anything else. A non-root `claude` user is created because `--dangerously-skip-permissions` refuses to run as root.
- **`claude-sandbox.sh`** — Shell function sourced from your `.zshrc`. Handles flag parsing, worktree creation, container naming (`<folder>-<random>` or `<branch>-<random>`), Docker container launch, and read-only GitHub token pass-through.
- **`init-firewall.sh`** — Network firewall script run at container startup. Fetches GitHub IP ranges, resolves allowlisted domains, builds an ipset, and applies iptables rules that DROP all outbound traffic not in the allowlist. Requires `--cap-add=NET_ADMIN --cap-add=NET_RAW`.
- **`$HOME:$HOME:ro` mount** — Your entire home directory is mounted read-only inside the container at the same path. The agent can read your models, data, virtualenvs, configs — anything. The `:ro` flag is kernel-enforced; even root inside the container cannot write through it. `~/.ssh` and `~/.config/gh` are hidden with empty tmpfs overlays so the agent cannot use your SSH keys or GitHub CLI credentials. `~/models` is mounted writable so the agent can download models. X11 display and auth are forwarded for clipboard image paste support. The host's PulseAudio socket and cookie are mounted so audio playback inside the container (e.g. `ffplay file.wav`) plays through the host's speakers.
- **`/workspace` mount** — The git repo (or worktree), mounted read-write. The only place the agent can make changes. With `--worktree`, the main repo's `.git` directory is also mounted writable so the agent can commit.
- **`settings.json`** — Default Claude Code settings baked into the image. Currently configures the status line to show `user@host:dir [model · ctx: XX%]`. The entrypoint merges these defaults into the container's settings on every start, preserving any other settings while always applying the status line.
- **`entrypoint.sh`** — Matches uid/gid, merges default settings, auto-detects llama.cpp, initializes the network firewall, installs deps (when `--env` is used), injects safety rules via `--append-system-prompt`, drops NET_ADMIN/NET_RAW capabilities, and launches Claude. The `~/.claude.json` config file is symlinked into `~/.claude/` so a single Docker volume persists all state.
- **`claude-config` volume** — Stores Claude's authentication and config. Lives in Docker's own storage, separate from your host's `~/.claude/`.
- **`uv-cache` volume** — Shared package download cache across all projects.

## Testing

Run the test suite to verify the sandbox isolation, GPU access, and tooling:

```bash
./test.sh
```

This builds the image and checks: host home is readable but not writable (even with sudo), workspace is writable, SSH keys are hidden and git push fails, GitHub CLI credentials are hidden, no-push rules are in the entrypoint, GPU/CUDA work, sudo works, uv/uvx, Claude Code, gh CLI, and xclip are available, the firewall blocks unauthorized domains and allows essential ones, terminal env is forwarded, default settings are baked into the image, PulseAudio socket is mounted, clipboard access works, `apt-get install` works through the firewall, container naming works, settings merge runs correctly, and the agent can commit inside a worktree.

## Managing volumes

```bash
# List volumes
docker volume ls

# Force re-login by deleting the config volume
docker volume rm claude-config

# Clear the package cache
docker volume rm uv-cache
```
