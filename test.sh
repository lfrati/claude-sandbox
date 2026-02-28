#!/bin/bash
set -euo pipefail

# Test the claude-sandbox container isolation:
#   - Host home dir is readable but not writable
#   - Workspace is writable
#   - GPU, CUDA, sudo, uv all work

PASS=0
FAIL=0

pass() { echo "  PASS: $1"; PASS=$((PASS + 1)); }
fail() { echo "  FAIL: $1"; FAIL=$((FAIL + 1)); }

echo "=== Building image ==="
docker build -t claude-sandbox .

echo ""
echo "=== Setting up test workspace ==="
WORKSPACE=$(mktemp -d)
echo "hello" > "$WORKSPACE/existing-file.txt"
trap 'rm -rf "$WORKSPACE"' EXIT

# Create a marker file in home dir to test reads
MARKER="$HOME/.claude-sandbox-test-marker"
echo "sandbox-test" > "$MARKER"
trap 'rm -f "$MARKER"; rm -rf "$WORKSPACE"' EXIT

echo ""
echo "=== Running tests inside container ==="

docker run --rm --gpus all \
  -v "$HOME:$HOME:ro" \
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
pass() { echo \"  PASS: \$1\"; ((PASS++)); }
fail() { echo \"  FAIL: \$1\"; ((FAIL++)); }

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

echo '--- 11. sudo apt-get install ---'
if sudo apt-get update -qq > /dev/null 2>&1 && sudo apt-get install -y -qq tree > /dev/null 2>&1 && tree --version > /dev/null 2>&1; then
  pass 'Can install packages via sudo apt-get'
else
  fail 'Cannot install packages via sudo apt-get'
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

echo ""
echo "=== Final: $PASS host-side checks passed, $FAIL failed ==="
