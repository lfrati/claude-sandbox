#!/bin/bash
set -euo pipefail

# Network firewall for claude-sandbox.
# Allowlists essential domains, blocks all other outbound traffic.
# Requires: --cap-add=NET_ADMIN --cap-add=NET_RAW

if ! iptables -L -n >/dev/null 2>&1; then
  echo "ERROR: iptables unavailable. Run with --cap-add=NET_ADMIN --cap-add=NET_RAW" >&2
  exit 1
fi

# Save Docker internal DNS rules before flushing
DOCKER_DNS_RULES=$(iptables-save -t nat | grep "127\.0\.0\.11" || true)

# Flush all existing rules
iptables -F
iptables -X
iptables -t nat -F
iptables -t nat -X
iptables -t mangle -F
iptables -t mangle -X
ipset destroy allowed-domains 2>/dev/null || true

# Restore Docker DNS resolution
if [ -n "$DOCKER_DNS_RULES" ]; then
  iptables -t nat -N DOCKER_OUTPUT 2>/dev/null || true
  iptables -t nat -N DOCKER_POSTROUTING 2>/dev/null || true
  echo "$DOCKER_DNS_RULES" | xargs -L 1 iptables -t nat
fi

# Allow DNS and localhost before restrictions
iptables -A OUTPUT -p udp --dport 53 -j ACCEPT
iptables -A INPUT -p udp --sport 53 -j ACCEPT
iptables -A INPUT -i lo -j ACCEPT
iptables -A OUTPUT -o lo -j ACCEPT

# Create ipset for allowed destination IPs
ipset create allowed-domains hash:net

# Fetch and add GitHub IP ranges
echo "Firewall: fetching GitHub IP ranges..."
gh_ranges=$(curl -sf --connect-timeout 5 https://api.github.com/meta) || {
  echo "ERROR: Failed to fetch GitHub IP ranges" >&2
  exit 1
}

if ! echo "$gh_ranges" | jq -e '.web and .api and .git' >/dev/null 2>&1; then
  echo "ERROR: GitHub API response missing required fields" >&2
  exit 1
fi

while read -r cidr; do
  ipset add allowed-domains "$cidr" 2>/dev/null || true
done < <(echo "$gh_ranges" | jq -r '(.web + .api + .git)[]')

# Resolve and add allowed domains
ALLOWED_DOMAINS=(
  # Claude Code
  api.anthropic.com
  claude.ai
  sentry.io
  statsig.anthropic.com
  statsig.com
  # Python packages
  pypi.org
  files.pythonhosted.org
  # npm
  registry.npmjs.org
  # Ubuntu apt repos
  archive.ubuntu.com
  security.ubuntu.com
  # HuggingFace
  huggingface.co
  cdn-lfs.hf.co
  cdn-lfs-us-1.hf.co
)

for domain in "${ALLOWED_DOMAINS[@]}"; do
  ips=$(dig +noall +answer A "$domain" 2>/dev/null | awk '$4 == "A" {print $5}')
  if [ -z "$ips" ]; then
    echo "WARNING: Failed to resolve $domain" >&2
    continue
  fi
  while read -r ip; do
    ipset add allowed-domains "$ip" 2>/dev/null || true
  done <<< "$ips"
done

# Allow host/Docker network
HOST_IP=$(ip route | grep default | cut -d" " -f3)
if [ -n "$HOST_IP" ]; then
  HOST_NETWORK=$(echo "$HOST_IP" | sed 's/\.[0-9]*$/.0\/24/')
  iptables -A INPUT -s "$HOST_NETWORK" -j ACCEPT
  iptables -A OUTPUT -d "$HOST_NETWORK" -j ACCEPT
fi

# Default policy: drop everything
iptables -P INPUT DROP
iptables -P FORWARD DROP
iptables -P OUTPUT DROP

# Drop all IPv6 traffic (firewall only covers IPv4)
ip6tables -P INPUT DROP
ip6tables -P OUTPUT DROP
ip6tables -P FORWARD DROP
ip6tables -A INPUT -i lo -j ACCEPT
ip6tables -A OUTPUT -o lo -j ACCEPT

# Allow established connections
iptables -A INPUT -m state --state ESTABLISHED,RELATED -j ACCEPT
iptables -A OUTPUT -m state --state ESTABLISHED,RELATED -j ACCEPT

# Allow traffic to allowlisted IPs only
iptables -A OUTPUT -m set --match-set allowed-domains dst -j ACCEPT

# Reject everything else with immediate feedback
iptables -A OUTPUT -j REJECT --reject-with icmp-admin-prohibited

# Verify: blocked domain must fail
if curl --connect-timeout 3 -sf https://example.com >/dev/null 2>&1; then
  echo "ERROR: Firewall verification failed — example.com is reachable" >&2
  exit 1
fi

echo "Firewall active. Allowed: GitHub, Anthropic, PyPI, npm, apt, HuggingFace."
