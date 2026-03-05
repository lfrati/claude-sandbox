CLAUDE_SANDBOX_VERSION="0.5.0"

claude-sandbox() {
  if [ "$1" = "--version" ]; then
    echo "claude-sandbox v$CLAUDE_SANDBOX_VERSION"
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
    -e "COLORTERM=$COLORTERM"
    -e "DISPLAY=$DISPLAY"
    -e "XAUTHORITY=/tmp/.Xauthority"
    -v /tmp/.X11-unix:/tmp/.X11-unix:ro
    -v "${XAUTHORITY:-$HOME/.Xauthority}:/tmp/.Xauthority:ro"
    "${env_flag[@]}")
  if [ -n "$web" ]; then
    local port
    port=$(python3 -c 'import socket; s=socket.socket(); s.bind(("",0)); print(s.getsockname()[1]); s.close()')
    local cid
    cid=$(docker run -d \
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
    docker run --rm -it "${flags[@]}" claude-sandbox "${args[@]}"
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
