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
# Copy CLAUDE.md into the test workspace
cp "$(dirname "$0")/CLAUDE.md" "$WORKSPACE/CLAUDE.md"
git -C "$WORKSPACE" add CLAUDE.md
git -C "$WORKSPACE" -c user.name=test -c user.email=test@test commit -q -m "add CLAUDE.md"
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
  -v "$WORKSPACE:/workspace" \
  -v claude-config:/home/claude/.claude \
  -v uv-cache:/uv-cache \
  -e "HOST_HOME=$HOME" \
  -e "HOST_UID=$(id -u)" \
  -e "HOST_GID=$(id -g)" \
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
if gosu claude sh -c 'echo test-output > /workspace/test-write.txt' 2>/dev/null; then
  pass 'Can write to workspace (as claude user)'
else
  fail 'Cannot write to workspace'
fi

echo '--- 4b. File ownership matches host user ---'
FILE_UID=\$(stat -c %u /workspace/test-write.txt)
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
cd /workspace
PUSH_OUTPUT=\$(gosu claude env GIT_SSH_COMMAND='ssh -o BatchMode=yes -o StrictHostKeyChecking=no -o ConnectTimeout=5' git push origin main 2>&1) || true
if echo \"\$PUSH_OUTPUT\" | grep -qiE 'denied|fatal|error|could not|permission|connection refused|resolve|no such|Host key'; then
  pass 'git push correctly fails without SSH keys'
else
  fail \"git push did not fail as expected: \$PUSH_OUTPUT\"
fi

echo '--- 14. CLAUDE.md found and readable ---'
if [ -f /workspace/CLAUDE.md ] && grep -q 'NEVER.*push' /workspace/CLAUDE.md; then
  pass 'CLAUDE.md found in workspace with no-push instructions'
else
  fail 'CLAUDE.md not found or missing no-push instructions'
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

echo ""
echo "=== Final: $PASS host-side checks passed, $FAIL failed ==="
