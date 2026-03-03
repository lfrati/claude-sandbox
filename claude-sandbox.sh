claude-sandbox() {
  if ! git rev-parse --is-inside-work-tree &>/dev/null; then
    echo "Error: not inside a git repository." >&2
    return 1
  fi
  local web=""
  local env_flag=()
  local args=()
  while [ $# -gt 0 ]; do
    case "$1" in
      --web)  web=1; shift ;;
      --env)  env_flag=(-e "SANDBOX_ENV=$2"); shift 2 ;;
      *)      args+=("$1"); shift ;;
    esac
  done
  mkdir -p "$HOME/models"
  local flags=(--init --gpus all
    -v "$HOME:$HOME:ro"
    -v "$HOME/models:$HOME/models"
    --tmpfs "$HOME/.ssh:ro,size=0"
    --tmpfs "$HOME/.config/gh:ro,size=0"
    -v "$(git rev-parse --show-toplevel)":/workspace
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
}
