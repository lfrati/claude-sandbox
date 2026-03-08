CLAUDE_SANDBOX_VERSION="0.5.0"

claude-sandbox() {
  if [ "$1" = "--version" ]; then
    echo "claude-sandbox v$CLAUDE_SANDBOX_VERSION"
    return 0
  fi
  if [ "$1" = "--help" ] || [ "$1" = "-h" ]; then
    cat <<EOF
claude-sandbox v$CLAUDE_SANDBOX_VERSION — Run Claude Code in a GPU-enabled Docker sandbox

Usage: claude-sandbox [options] [-- claude-args...]

Options:
  --env <file>        Install dependencies before Claude starts
                      Supports: uv.lock, requirements.txt, pyproject.toml
  --web               Start as a web terminal (ttyd + Tailscale serve)
  --worktree <name>   Run in an isolated git worktree (.worktrees/<name>/)
  --version           Show version
  -h, --help          Show this help

Extra arguments are forwarded to Claude Code. Run inside a git repo.

Examples:
  claude-sandbox                                    # interactive session
  claude-sandbox -p "fix the login bug"             # one-shot prompt
  claude-sandbox --model sonnet -p "refactor auth"  # choose model
  claude-sandbox --env uv.lock                      # install deps first
  claude-sandbox --web                              # web terminal on tailnet
  claude-sandbox --worktree feature-auth            # isolated worktree
EOF
    return 0
  fi
  if ! git rev-parse --is-inside-work-tree &>/dev/null; then
    echo "Error: not inside a git repository." >&2
    return 1
  fi
  local web="" worktree=""
  local env_flag=()
  local args=()
  while [ $# -gt 0 ]; do
    case "$1" in
      --web)      web=1; shift ;;
      --worktree) worktree="$2"; shift 2 ;;
      --env)      env_flag=(-e "SANDBOX_ENV=$2"); shift 2 ;;
      *)          args+=("$1"); shift ;;
    esac
  done

  local repo_root
  repo_root=$(git rev-parse --show-toplevel)
  local mount_dir="$repo_root"

  # Container name: foldername-random (or branchname-random for worktrees)
  local name_base
  if [ -n "$worktree" ]; then
    name_base="$worktree"
  else
    name_base=$(basename "$repo_root")
  fi
  local container_name="${name_base}-$(shuf -i 1000-9999 -n 1)"

  # Set up worktree if requested
  if [ -n "$worktree" ]; then
    local wt_dir="$repo_root/.worktrees/$worktree"
    if [ -d "$wt_dir" ]; then
      echo "Using existing worktree: $wt_dir"
    elif git show-ref --verify --quiet "refs/heads/$worktree" 2>/dev/null; then
      echo "Creating worktree for existing branch: $worktree"
      git worktree add "$wt_dir" "$worktree"
    else
      echo "Creating worktree with new branch: $worktree"
      git worktree add -b "$worktree" "$wt_dir"
    fi
    mount_dir="$wt_dir"
  fi

  mkdir -p "$HOME/models"
  local flags=(--init --gpus all
    -v "$HOME:$HOME:ro"
    -v "$HOME/models:$HOME/models"
    --tmpfs "$HOME/.ssh:ro,size=0"
    --tmpfs "$HOME/.config/gh:ro,size=0"
    -v "$mount_dir:$mount_dir"
    -w "$mount_dir"
    -e "WORKSPACE_DIR=$mount_dir")
  # Worktree .git file points back to main repo's .git/ via absolute path.
  # Mount it writable so the agent can commit and stage.
  if [ -n "$worktree" ]; then
    flags+=(-v "$repo_root/.git:$repo_root/.git")
  fi
  flags+=(
    -v claude-config:/home/claude/.claude
    -v uv-cache:/uv-cache
    -e "HOST_HOME=$HOME"
    -e "HOST_UID=$(id -u)"
    -e "HOST_GID=$(id -g)"
    -e "TERM=$TERM"
    -e "DISPLAY=${DISPLAY:-}"
    -e "XAUTHORITY=/tmp/.Xauthority"
    -v /tmp/.X11-unix:/tmp/.X11-unix:ro
    -v "${XAUTHORITY:-$HOME/.Xauthority}:/tmp/.Xauthority:ro"
    -v "${XDG_RUNTIME_DIR:-/run/user/$(id -u)}/pulse/native:/tmp/pulse-native"
    -v "$HOME/.config/pulse/cookie:/tmp/pulse-cookie:ro"
    -e "PULSE_SERVER=unix:/tmp/pulse-native"
    -e "PULSE_COOKIE=/tmp/pulse-cookie"
    "${env_flag[@]}")
  if [ -n "$web" ]; then
    local port
    port=$(python3 -c 'import socket; s=socket.socket(); s.bind(("",0)); print(s.getsockname()[1]); s.close()')
    local cid
    cid=$(docker run -d --name "$container_name" \
      -e "SANDBOX_MODE=web" -e "SANDBOX_PORT=$port" -p "127.0.0.1:$port:$port" \
      "${flags[@]}" claude-sandbox "${args[@]}") || { echo "Error: container failed to start." >&2; return 1; }
    echo "Container: ${cid:0:12}"
    if ! tailscale serve --bg "http://127.0.0.1:$port"; then
      echo "Error: tailscale serve failed. Stopping container." >&2
      docker rm -f "$cid" >/dev/null 2>&1
      return 1
    fi
    echo "Stop: docker rm -f ${cid:0:12}"
    # When the container exits, tear down tailscale serve
    { docker wait "$cid" >/dev/null 2>&1
      tailscale serve --https=443 off
      echo "Tailscale serve stopped."
    } &!
  else
    docker run --rm -it --name "$container_name" "${flags[@]}" claude-sandbox "${args[@]}"
  fi

  # After the container exits, show worktree info
  if [ -n "$worktree" ]; then
    echo ""
    echo "Worktree: $mount_dir"
    echo "Branch:   $worktree"
    echo "Review:   cd $mount_dir && git diff"
    echo "Push:     git push origin $worktree"
    echo "Cleanup:  git worktree remove .worktrees/$worktree"
  fi
}

# Completions
if [ -n "$ZSH_VERSION" ]; then
  _claude-sandbox() {
    local -a opts=('--env[Install dependencies before Claude starts]:file:_files'
      '--web[Start as a web terminal]'
      '--worktree[Run in an isolated git worktree]:branch:{compadd $(git branch --format="%(refname:short)" 2>/dev/null)}'
      '--version[Show version]'
      '--help[Show help]'
      '-h[Show help]')
    _arguments -s "$opts[@]"
  }
  compdef _claude-sandbox claude-sandbox
elif [ -n "$BASH_VERSION" ]; then
  _claude_sandbox_completions() {
    local cur prev
    cur="${COMP_WORDS[COMP_CWORD]}"
    prev="${COMP_WORDS[COMP_CWORD-1]}"
    case "$prev" in
      --env)      COMPREPLY=($(compgen -f -- "$cur")); return ;;
      --worktree) COMPREPLY=($(compgen -W "$(git branch --format='%(refname:short)' 2>/dev/null)" -- "$cur")); return ;;
    esac
    if [[ "$cur" == -* ]]; then
      COMPREPLY=($(compgen -W "--env --web --worktree --version --help -h" -- "$cur"))
    fi
  }
  complete -F _claude_sandbox_completions claude-sandbox
fi
