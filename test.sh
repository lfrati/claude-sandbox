#!/bin/bash
set -euo pipefail

# Test the claude-sandbox container isolation:
#   - Host home dir is readable but not writable
#   - Workspace is writable
#   - SSH keys hidden, git push blocked
#   - GPU, CUDA, sudo, uv all work

PASS=0
FAIL=0

pass() { echo -e "  \033[32mPASS: $1\033[0m"; PASS=$((PASS + 1)); }
fail() { echo -e "  \033[31mFAIL: $1\033[0m"; FAIL=$((FAIL + 1)); }

echo "=== Building image ==="
docker build -t claude-sandbox .

echo ""
echo "=== Setting up test workspace ==="
WORKSPACE=$(mktemp -d)
echo "hello" > "$WORKSPACE/existing-file.txt"
# Initialize workspace as a git repo with a dummy remote so we can test push failure
git -C "$WORKSPACE" init -q
git -C "$WORKSPACE" remote add origin git@github.com:test/nonexistent.git
git -C "$WORKSPACE" add -A
git -C "$WORKSPACE" -c user.name=test -c user.email=test@test commit -q -m "init"
trap 'rm -rf "$WORKSPACE"' EXIT

# Create a marker file in home dir to test reads
MARKER="$HOME/.claude-sandbox-test-marker"
echo "sandbox-test" > "$MARKER"
trap 'rm -f "$MARKER"; rm -rf "$WORKSPACE"' EXIT

echo ""
echo "=== Running tests inside container ==="

docker run --rm --gpus all \
  -v "$HOME:$HOME:ro" \
  --tmpfs "$HOME/.ssh:ro,size=0" \
  --tmpfs "$HOME/.config/gh:ro,size=0" \
  -v "$WORKSPACE:$WORKSPACE" \
  -w "$WORKSPACE" \
  -e "WORKSPACE_DIR=$WORKSPACE" \
  -v claude-config:/home/claude/.claude \
  -v uv-cache:/uv-cache \
  -e "HOST_HOME=$HOME" \
  -e "HOST_UID=$(id -u)" \
  -e "HOST_GID=$(id -g)" \
  -e "TERM=$TERM" \
  -e "DISPLAY=$DISPLAY" \
  -e "XAUTHORITY=/tmp/.Xauthority" \
  -v /tmp/.X11-unix:/tmp/.X11-unix:ro \
  -v "${XAUTHORITY:-$HOME/.Xauthority}:/tmp/.Xauthority:ro" \
  -v "${XDG_RUNTIME_DIR:-/run/user/$(id -u)}/pulse/native:/tmp/pulse-native" \
  -v "$HOME/.config/pulse/cookie:/tmp/pulse-cookie:ro" \
  -e "PULSE_SERVER=unix:/tmp/pulse-native" \
  -e "PULSE_COOKIE=/tmp/pulse-cookie" \
  --entrypoint /bin/bash \
  claude-sandbox -c "
set +e
PASS=0
FAIL=0
pass() { echo -e \"  \033[32mPASS: \$1\033[0m\"; ((PASS++)); }
fail() { echo -e \"  \033[31mFAIL: \$1\033[0m\"; ((FAIL++)); }

# Replay the uid/gid matching from entrypoint (since we override it)
if [ -n \"\$HOST_UID\" ] && [ \"\$HOST_UID\" != \"\$(id -u claude)\" ]; then
  usermod -u \"\$HOST_UID\" claude
fi
if [ -n \"\$HOST_GID\" ] && [ \"\$HOST_GID\" != \"\$(getent group claude | cut -d: -f3)\" ]; then
  groupmod -g \"\$HOST_GID\" claude
fi
chown claude:claude /home/claude/.claude 2>/dev/null || true
ln -sf /home/claude/.claude/.claude.json /home/claude/.claude.json 2>/dev/null || true

echo '--- 1. Read access to host home directory ---'
if cat \"$HOME/.claude-sandbox-test-marker\" 2>/dev/null | grep -q sandbox-test; then
  pass 'Can read host home directory files'
else
  fail 'Cannot read host home directory files'
fi

echo '--- 2. Write protection on host home directory ---'
if touch \"$HOME/.claude-sandbox-test-write\" 2>/dev/null; then
  fail 'Was able to write to host home directory (read-only mount broken!)'
  rm -f \"$HOME/.claude-sandbox-test-write\"
else
  pass 'Cannot write to host home directory'
fi

echo '--- 3. Write protection with sudo ---'
if sudo touch \"$HOME/.claude-sandbox-test-write\" 2>/dev/null; then
  fail 'sudo was able to write to host home directory!'
  sudo rm -f \"$HOME/.claude-sandbox-test-write\"
else
  pass 'Even sudo cannot write to host home directory'
fi

echo '--- 4. Write access to workspace ---'
if gosu claude sh -c 'echo test-output > $WORKSPACE/test-write.txt' 2>/dev/null; then
  pass 'Can write to workspace (as claude user)'
else
  fail 'Cannot write to workspace'
fi

echo '--- 4b. File ownership matches host user ---'
FILE_UID=\$(stat -c %u $WORKSPACE/test-write.txt)
if [ \"\$FILE_UID\" = \"\$HOST_UID\" ]; then
  pass \"Files owned by host uid (\$HOST_UID)\"
else
  fail \"File owned by uid \$FILE_UID, expected \$HOST_UID\"
fi

echo '--- 5. GPU access ---'
if nvidia-smi > /dev/null 2>&1; then
  pass 'nvidia-smi works'
else
  fail 'nvidia-smi not available'
fi

echo '--- 6. CUDA compiler ---'
if nvcc --version > /dev/null 2>&1; then
  pass 'nvcc available'
else
  fail 'nvcc not available'
fi

echo '--- 7. Passwordless sudo ---'
if sudo whoami 2>/dev/null | grep -q root; then
  pass 'sudo works (passwordless)'
else
  fail 'sudo not working'
fi

echo '--- 8. uv ---'
if uv --version > /dev/null 2>&1; then
  pass 'uv available'
else
  fail 'uv not available'
fi

echo '--- 9. Claude Code ---'
if claude --version > /dev/null 2>&1; then
  pass 'claude available'
else
  fail 'claude not available'
fi

echo '--- 10. Claude Code authenticated ---'
CLAUDE_REPLY=\$(gosu claude claude --dangerously-skip-permissions -p 'respond with exactly: SANDBOX_OK' --max-turns 1 2>/dev/null)
if echo \"\$CLAUDE_REPLY\" | grep -q 'SANDBOX_OK'; then
  pass 'Claude is logged in and responding'
else
  fail 'Claude is not logged in or not responding (run claude-sandbox and use /login first)'
fi

echo '--- 11. SSH keys hidden ---'
if [ -d \"$HOME/.ssh\" ] && [ -z \"\$(ls -A \"$HOME/.ssh\" 2>/dev/null)\" ]; then
  pass 'Host ~/.ssh is empty (tmpfs overlay hiding keys)'
elif [ ! -d \"$HOME/.ssh\" ]; then
  pass 'Host ~/.ssh does not exist'
else
  fail \"~/.ssh is not empty: \$(ls \"$HOME/.ssh\")\"
fi

echo '--- 12. GitHub CLI credentials hidden ---'
if [ -d \"$HOME/.config/gh\" ] && [ -z \"\$(ls -A \"$HOME/.config/gh\" 2>/dev/null)\" ]; then
  pass 'Host ~/.config/gh is empty (tmpfs overlay hiding credentials)'
elif [ ! -d \"$HOME/.config/gh\" ]; then
  pass 'Host ~/.config/gh does not exist'
else
  fail \"~/.config/gh is not empty: \$(ls \"$HOME/.config/gh\")\"
fi

# Verify gh can't authenticate even if installed
if command -v gh >/dev/null 2>&1 || (sudo apt-get update -qq >/dev/null 2>&1 && sudo apt-get install -y -qq gh >/dev/null 2>&1); then
  GH_OUTPUT=\$(gh auth status 2>&1) || true
  if echo \"\$GH_OUTPUT\" | grep -qi 'Logged in to'; then
    fail \"gh is authenticated: \$GH_OUTPUT\"
  else
    pass 'gh is not authenticated (no credentials available)'
  fi
else
  pass 'gh not installed and not installable (credentials inaccessible either way)'
fi

echo '--- 13. Git push fails without SSH keys ---'
cd $WORKSPACE
PUSH_OUTPUT=\$(gosu claude env GIT_SSH_COMMAND='ssh -o BatchMode=yes -o StrictHostKeyChecking=no -o ConnectTimeout=5' git push origin main 2>&1) || true
if echo \"\$PUSH_OUTPUT\" | grep -qiE 'denied|fatal|error|could not|permission|connection refused|resolve|no such|Host key'; then
  pass 'git push correctly fails without SSH keys'
else
  fail \"git push did not fail as expected: \$PUSH_OUTPUT\"
fi

echo '--- 14. No-push rules in entrypoint ---'
if grep -q 'NEVER.*push' /entrypoint.sh; then
  pass 'No-push rules present in entrypoint'
else
  fail 'No-push rules missing from entrypoint'
fi

echo '--- 15. sudo apt-get install ---'
if sudo apt-get update -qq > /dev/null 2>&1 && sudo apt-get install -y -qq tree > /dev/null 2>&1 && tree --version > /dev/null 2>&1; then
  pass 'Can install packages via sudo apt-get'
else
  fail 'Cannot install packages via sudo apt-get'
fi

echo '--- 16. ttyd available ---'
if ttyd --version > /dev/null 2>&1; then
  pass 'ttyd available'
else
  fail 'ttyd not available'
fi

echo '--- 17. uvx hf available ---'
if gosu claude uvx --from huggingface-hub hf version > /dev/null 2>&1; then
  pass 'uvx hf works'
else
  fail 'uvx hf not working'
fi

echo '--- 18. Terminal env forwarded ---'
if [ -n \"\$TERM\" ]; then
  pass \"TERM=\$TERM\"
else
  fail \"TERM not set\"
fi

echo '--- 19. Settings defaults baked into image ---'
if [ -f /etc/claude-defaults/settings.json ] && jq -e '.statusLine.command' /etc/claude-defaults/settings.json > /dev/null 2>&1; then
  pass 'Default settings.json has statusLine config'
else
  fail 'Default settings.json missing or no statusLine in /etc/claude-defaults/'
fi

echo '--- 20. Audio output (PulseAudio) ---'
if [ -S /tmp/pulse-native ] && gosu claude ffplay -nodisp -autoexit /test-beep.wav > /dev/null 2>&1; then
  pass 'Audio playback works (PulseAudio)'
else
  fail 'Audio playback failed (PulseAudio socket or ffplay issue)'
fi

echo '--- 21. Clipboard access (xclip) ---'
if gosu claude xclip -selection clipboard -t TARGETS -o > /dev/null 2>&1; then
  pass 'xclip can connect to X11 display (as claude user)'
else
  fail 'xclip cannot connect to X11 display (as claude user)'
fi

echo ''
echo \"=== Results: \$PASS passed, \$FAIL failed ===\"
[ \$FAIL -eq 0 ] && exit 0 || exit 1
"

echo ""
echo "=== Host-side verification ==="

if [ -f "$WORKSPACE/test-write.txt" ]; then
  pass "Workspace writes are visible on host"
else
  fail "Workspace writes not visible on host"
fi

HOST_FILE_UID=$(stat -c %u "$WORKSPACE/test-write.txt")
HOST_FILE_GID=$(stat -c %g "$WORKSPACE/test-write.txt")
if [ "$HOST_FILE_UID" = "$(id -u)" ] && [ "$HOST_FILE_GID" = "$(id -g)" ]; then
  pass "File ownership correct on host (uid=$(id -u), gid=$(id -g))"
else
  fail "File owned by $HOST_FILE_UID:$HOST_FILE_GID on host, expected $(id -u):$(id -g)"
fi

if [ ! -f "$HOME/.claude-sandbox-test-write" ]; then
  pass "No stray writes in host home directory"
else
  fail "Found unexpected write in host home directory!"
  rm -f "$HOME/.claude-sandbox-test-write"
fi

if command -v tailscale >/dev/null 2>&1 && tailscale status >/dev/null 2>&1; then
  pass "tailscale installed and connected"
else
  fail "tailscale not installed or not connected (required for --web mode)"
fi

# Test settings.json merge via entrypoint
SETTINGS_OUTPUT=$(docker run --rm \
  -v claude-config:/home/claude/.claude \
  -e "HOST_UID=$(id -u)" \
  -e "HOST_GID=$(id -g)" \
  claude-sandbox --version 2>/dev/null) || true
# Now check the volume has the merged settings
SETTINGS_CHECK=$(docker run --rm \
  -v claude-config:/home/claude/.claude \
  --entrypoint /bin/bash \
  claude-sandbox -c "jq -e '.statusLine.command' /home/claude/.claude/settings.json 2>/dev/null" 2>&1) || true
if echo "$SETTINGS_CHECK" | grep -q 'whoami'; then
  pass "Entrypoint merges statusLine into settings.json"
else
  fail "Entrypoint did not merge statusLine ($SETTINGS_CHECK)"
fi

# Test container naming: verify name appears in docker ps
CONTAINER_NAME="test-sandbox-$$"
CID=$(docker run -d --name "$CONTAINER_NAME" \
  --entrypoint /bin/bash \
  claude-sandbox -c "sleep 5" 2>&1)
if docker ps --format '{{.Names}}' | grep -q "^${CONTAINER_NAME}$"; then
  pass "Container named correctly ($CONTAINER_NAME)"
else
  fail "Container name not found in docker ps"
fi
docker rm -f "$CONTAINER_NAME" >/dev/null 2>&1

# Test worktree support: create a worktree, run a container, verify commit works
WT_BRANCH="test-worktree-$$"
WT_DIR="$WORKSPACE/.worktrees/$WT_BRANCH"
git -C "$WORKSPACE" worktree add -b "$WT_BRANCH" "$WT_DIR" >/dev/null 2>&1

WT_OUTPUT=$(docker run --rm --init --gpus all \
  -v "$HOME:$HOME:ro" \
  -v "$WT_DIR:$WT_DIR" \
  -w "$WT_DIR" \
  -e "WORKSPACE_DIR=$WT_DIR" \
  -v "$WORKSPACE/.git:$WORKSPACE/.git" \
  -e "HOST_UID=$(id -u)" \
  -e "HOST_GID=$(id -g)" \
  --entrypoint /bin/bash \
  claude-sandbox -c "
    if [ -n \"\$HOST_UID\" ]; then usermod -u \"\$HOST_UID\" claude 2>/dev/null; fi
    if [ -n \"\$HOST_GID\" ]; then groupmod -g \"\$HOST_GID\" claude 2>/dev/null; fi
    gosu claude bash -c '
      echo worktree-test > $WT_DIR/wt-test.txt &&
      cd $WT_DIR &&
      git add wt-test.txt &&
      git -c user.name=test -c user.email=test@test commit -q -m \"worktree commit\" 2>&1
    '
  " 2>&1)

if git -C "$WT_DIR" log --oneline -1 2>/dev/null | grep -q "worktree commit"; then
  pass "Worktree: agent can commit in worktree"
else
  fail "Worktree: agent cannot commit in worktree ($WT_OUTPUT)"
fi

git -C "$WORKSPACE" worktree remove "$WT_DIR" --force 2>/dev/null
git -C "$WORKSPACE" branch -D "$WT_BRANCH" 2>/dev/null

echo ""
echo "=== Final: $PASS host-side checks passed, $FAIL failed ==="
