CLAUDE_SANDBOX_VERSION="0.6.0"

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
  --shell             Drop into a bash shell instead of Claude
  --worktree <name>   Run in an isolated git worktree (.worktrees/<name>/)
  --version           Show version
  -h, --help          Show this help

Network firewall is always active (iptables allowlist).
Set SANDBOX_GH_TOKEN to a read-only GitHub PAT for gh CLI access.

Extra arguments are forwarded to Claude Code. Run inside a git repo.

Examples:
  claude-sandbox                                    # interactive session
  claude-sandbox -p "fix the login bug"             # one-shot prompt
  claude-sandbox --model sonnet -p "refactor auth"  # choose model
  claude-sandbox --env uv.lock                      # install deps first
  claude-sandbox --shell                            # bash shell in sandbox
  claude-sandbox --worktree feature-auth            # isolated worktree
EOF
    return 0
  fi
  if ! git rev-parse --is-inside-work-tree &>/dev/null; then
    echo "Error: not inside a git repository." >&2
    return 1
  fi
  local worktree="" shell="" sandbox_env=""
  local args=()
  while [ $# -gt 0 ]; do
    case "$1" in
      --shell)    shell=1; shift ;;
      --worktree) worktree="$2"; shift 2 ;;
      --env)      sandbox_env="$2"; shift 2 ;;
      *)          args+=("$1"); shift ;;
    esac
  done

  local repo_root
  repo_root=$(git rev-parse --show-toplevel) || { echo "Error: failed to determine repository root." >&2; return 1; }
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
      git worktree add "$wt_dir" "$worktree" || { echo "Error: failed to create worktree for branch '$worktree'." >&2; return 1; }
    else
      echo "Creating worktree with new branch: $worktree"
      git worktree add -b "$worktree" "$wt_dir" || { echo "Error: failed to create worktree with new branch '$worktree'." >&2; return 1; }
    fi
    mount_dir="$wt_dir"
  fi

  # Validate env file exists on host before starting container
  local env_flag=()
  if [ -n "$sandbox_env" ]; then
    if [ ! -f "$mount_dir/$sandbox_env" ]; then
      echo "Error: env file '$sandbox_env' not found in $mount_dir." >&2
      return 1
    fi
    env_flag=(-e "SANDBOX_ENV=$sandbox_env")
  fi

  # Check image exists
  if ! docker image inspect claude-sandbox >/dev/null 2>&1; then
    echo "Error: claude-sandbox image not found. Build it with: docker build -t claude-sandbox ." >&2
    return 1
  fi

  mkdir -p "$HOME/models" || { echo "Error: failed to create ~/models directory." >&2; return 1; }
  local flags=(--init --gpus all
    --cap-add=NET_ADMIN --cap-add=NET_RAW
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
  # Pass read-only GitHub token if set
  if [ -n "${SANDBOX_GH_TOKEN:-}" ]; then
    flags+=(-e "GH_TOKEN=$SANDBOX_GH_TOKEN")
  fi
  if [ -n "$shell" ]; then
    docker run --rm -it --name "$container_name" -e "SANDBOX_MODE=shell" "${flags[@]}" claude-sandbox
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
      '--shell[Drop into a bash shell]'
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
      COMPREPLY=($(compgen -W "--env --shell --worktree --version --help -h" -- "$cur"))
    fi
  }
  complete -F _claude_sandbox_completions claude-sandbox
fi
