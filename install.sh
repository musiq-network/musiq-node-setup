#!/usr/bin/env bash
# MusIQ Node agent installer.
#
#   sudo bash <(curl -fsSL https://raw.githubusercontent.com/musiq-network/musiq-node-setup/main/install.sh)
#
# Interactive by default. Hosts can install non-interactively with environment
# variables (see README): MUSIQ_LICENSE_KEY, or MUSIQ_LICENSE_ID with
# MUSIQ_HOST_API_KEY; MUSIQ_API_BASE. Hosts running many nodes per server
# should use musiq-host.sh instead (one service for every node).
#
#   sudo bash install.sh --uninstall     remove the agent (keeps nothing behind)
set -euo pipefail

AGENT_VERSION="1.0.0"
API_BASE="${MUSIQ_API_BASE:-https://musiqnetwork.com}"
AGENT_DIR="/opt/musiq-agent"
SERVICE="musiq-agent"
RAW_BASE="${MUSIQ_RAW_BASE:-https://raw.githubusercontent.com/musiq-network/musiq-node-setup/main}"
# Heartbeat schedule (systemd OnCalendar). Rewards count one heartbeat per day;
# checking in every 6 hours means a short outage never costs a day.
SCHEDULE="${MUSIQ_SCHEDULE:-*-*-* 00/6:00:00}"

GREEN='\033[0;32m'; YELLOW='\033[1;33m'; RED='\033[0;31m'; NC='\033[0m'
info()  { echo -e "${GREEN}[musiq]${NC} $*"; }
warn()  { echo -e "${YELLOW}[musiq]${NC} $*"; }
error() { echo -e "${RED}[musiq]${NC} $*" >&2; exit 1; }

[ "$(id -u)" -eq 0 ] || error "Run as root: sudo bash install.sh"
command -v systemctl >/dev/null 2>&1 || error "systemd is required."

if [ "${1:-}" = "--uninstall" ]; then
  systemctl disable --now "${SERVICE}.timer" 2>/dev/null || true
  rm -f "/etc/systemd/system/${SERVICE}.service" "/etc/systemd/system/${SERVICE}.timer"
  systemctl daemon-reload
  rm -rf "$AGENT_DIR"
  info "MusIQ agent removed. Your license is unaffected; you can install again any time."
  exit 0
fi

# ---- dependencies ---------------------------------------------------------------
MISSING=()
for c in curl jq openssl; do command -v "$c" >/dev/null 2>&1 || MISSING+=("$c"); done
if [ ${#MISSING[@]} -gt 0 ]; then
  info "Installing: ${MISSING[*]}"
  apt-get update -q && apt-get install -y -q "${MISSING[@]}" >/dev/null || error "Could not install ${MISSING[*]}"
fi
TMPK=$(mktemp)
openssl genpkey -algorithm ed25519 -out "$TMPK" >/dev/null 2>&1 \
  || error "OpenSSL with Ed25519 support is required (OpenSSL 1.1.1+, e.g. Ubuntu 20.04+ / Debian 11+)."
rm -f "$TMPK"

# ---- license key ------------------------------------------------------------------
mkdir -p "$AGENT_DIR"
chmod 700 "$AGENT_DIR"
LICENSE_KEY="${MUSIQ_LICENSE_KEY:-}"
HOST_LICENSE_ID="${MUSIQ_LICENSE_ID:-}"
if [ -n "$HOST_LICENSE_ID" ]; then
  # Host install by license id: needs the host API key, never the member's license key.
  [ -n "${MUSIQ_HOST_API_KEY:-}" ] || error "MUSIQ_LICENSE_ID needs MUSIQ_HOST_API_KEY."
  [[ "$HOST_LICENSE_ID" =~ ^[A-Za-z0-9_-]{1,64}$ ]] || error "MUSIQ_LICENSE_ID is not a valid license id."
elif [ -z "$LICENSE_KEY" ] && [ -f "$AGENT_DIR/license.key" ]; then
  EXISTING=$(cat "$AGENT_DIR/license.key")
  read -rp "Existing license ${EXISTING:0:8}… found. Re-use it? [Y/n]: " REUSE
  [[ "${REUSE:-Y}" =~ ^[Yy]$ ]] && LICENSE_KEY="$EXISTING"
fi
if [ -z "$HOST_LICENSE_ID" ]; then
  if [ -z "$LICENSE_KEY" ]; then
    read -rp "Enter your MusIQ node license key (MSQ-XXXX-XXXX-XXXX): " LICENSE_KEY
  fi
  LICENSE_KEY=$(echo "$LICENSE_KEY" | tr '[:lower:]' '[:upper:]' | tr -d '[:space:]')
  [ -n "$LICENSE_KEY" ] || error "A license key is required."
fi
LABEL="${HOST_LICENSE_ID:-${LICENSE_KEY:0:8}…}"

# ---- node key (Ed25519). A new key is generated on every install (key rotation). --
info "Generating this node's signing key..."
openssl genpkey -algorithm ed25519 -out "$AGENT_DIR/node.key.new" >/dev/null 2>&1
chmod 600 "$AGENT_DIR/node.key.new"
PUBKEY=$(openssl pkey -in "$AGENT_DIR/node.key.new" -pubout -outform DER | tail -c 32 | base64 | tr -d '\n')

# ---- activate ---------------------------------------------------------------------
info "Activating license $LABEL with $API_BASE"
AUTH=()
[ -n "${MUSIQ_HOST_API_KEY:-}" ] && AUTH=(-H "X-ACCESS-KEY: ${MUSIQ_HOST_API_KEY}")
BYPASS=()
[ -n "${MUSIQ_BYPASS:-}" ] && BYPASS=(-H "x-vercel-protection-bypass: ${MUSIQ_BYPASS}")
if [ -n "$HOST_LICENSE_ID" ]; then
  BODY=$(jq -cn --arg id "$HOST_LICENSE_ID" --arg p "$PUBKEY" --arg v "$AGENT_VERSION" \
    '{licenseId:$id, nodePublicKey:$p, agentVersion:$v}')
else
  BODY=$(jq -cn --arg k "$LICENSE_KEY" --arg p "$PUBKEY" --arg v "$AGENT_VERSION" \
    '{licenseKey:$k, nodePublicKey:$p, agentVersion:$v}')
fi
RESP=$(curl -sS -w '\n%{http_code}' -X POST "$API_BASE/api/nodes/v1/activate" \
  -H "Content-Type: application/json" "${AUTH[@]}" "${BYPASS[@]}" -d "$BODY") || error "Could not reach $API_BASE"
CODE=$(echo "$RESP" | tail -1)
JSON=$(echo "$RESP" | sed '$d')
if [ "$CODE" != "200" ]; then
  rm -f "$AGENT_DIR/node.key.new"
  error "Activation failed ($CODE): $(echo "$JSON" | jq -r '.message // .error // "unknown error"' 2>/dev/null || echo "$JSON")"
fi
LICENSE_ID=$(echo "$JSON" | jq -r '.licenseId')
TOKEN_ID=$(echo "$JSON" | jq -r '.tokenId // "pending"')

mv "$AGENT_DIR/node.key.new" "$AGENT_DIR/node.key"
if [ -n "$LICENSE_KEY" ]; then
  echo "$LICENSE_KEY" > "$AGENT_DIR/license.key"
  chmod 600 "$AGENT_DIR/license.key"
fi
cat > "$AGENT_DIR/agent.env" <<EOF
MUSIQ_API_BASE=$API_BASE
MUSIQ_LICENSE_ID=$LICENSE_ID
${MUSIQ_BYPASS:+MUSIQ_BYPASS=$MUSIQ_BYPASS}
EOF
chmod 600 "$AGENT_DIR/agent.env"

# ---- agent + systemd timer ----------------------------------------------------------
if [ -f "$(dirname "$0")/musiq-agent.sh" ] && [ "${MUSIQ_LOCAL_AGENT:-}" = "1" ]; then
  cp "$(dirname "$0")/musiq-agent.sh" "$AGENT_DIR/musiq-agent.sh"
else
  curl -fsSL "$RAW_BASE/musiq-agent.sh" -o "$AGENT_DIR/musiq-agent.sh" || error "Could not download the agent."
fi
chmod 700 "$AGENT_DIR/musiq-agent.sh"

cat > "/etc/systemd/system/${SERVICE}.service" <<EOF
[Unit]
Description=MusIQ Node Agent (heartbeat)
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
EnvironmentFile=$AGENT_DIR/agent.env
ExecStart=$AGENT_DIR/musiq-agent.sh
StandardOutput=journal
StandardError=journal
EOF

cat > "/etc/systemd/system/${SERVICE}.timer" <<EOF
[Unit]
Description=MusIQ Node Agent heartbeat timer

[Timer]
OnCalendar=$SCHEDULE
RandomizedDelaySec=1800
Persistent=true
OnBootSec=2min

[Install]
WantedBy=timers.target
EOF

systemctl daemon-reload
systemctl enable --now "${SERVICE}.timer" >/dev/null
info "Sending first heartbeat..."
systemctl start "${SERVICE}.service" || warn "First heartbeat failed — the timer will retry. Check: journalctl -u ${SERVICE}"

info "Done. License $LABEL (token #${TOKEN_ID}) is active on this machine."
info "Status:  systemctl list-timers ${SERVICE}.timer   ·   Logs: journalctl -u ${SERVICE} -n 20"
