#!/usr/bin/env bash
# MusIQ host agent: runs many MusIQ nodes on one server, for hosting partners.
#
# One systemd timer sends a signed heartbeat for every node on this server. Each
# node has its own Ed25519 signing key under $HOST_DIR/nodes/<licenseId>/. Nodes
# are activated by license id with your host API key; members' license keys are
# never needed.
#
#   sudo MUSIQ_HOST_API_KEY=mnh_... ./musiq-host.sh setup     write config + install the timer
#   sudo ./musiq-host.sh activate <licenseId> [...]           add nodes
#   sudo ./musiq-host.sh activate-file ids.txt                add nodes, one license id per line
#   sudo ./musiq-host.sh heartbeat                            check in every node now
#   sudo ./musiq-host.sh status                               list nodes and their last result
#   sudo ./musiq-host.sh remove <licenseId> [...]             stop hosting nodes (deletes their keys)
#   sudo ./musiq-host.sh uninstall                            remove the timer, config and all keys
#
# Config ($HOST_DIR/host.env, mode 600): MUSIQ_API_BASE, MUSIQ_HOST_API_KEY,
# optional MUSIQ_BYPASS (dev only), MUSIQ_PARALLEL (default 16).
set -euo pipefail

AGENT_VERSION="host-1.0.0"
HOST_DIR="${MUSIQ_HOST_DIR:-/opt/musiq-host}"
NODES="$HOST_DIR/nodes"
SERVICE="musiq-host"
SCHEDULE="${MUSIQ_SCHEDULE:-*-*-* 00/6:00:00}"

log()   { echo "[$(date -u '+%Y-%m-%dT%H:%M:%SZ')] [musiq-host] $*"; }
error() { echo "[musiq-host] $*" >&2; exit 1; }

load_config() {
  [ -f "$HOST_DIR/host.env" ] || error "Not set up yet: run '$0 setup' first."
  # shellcheck disable=SC1091
  set -a; . "$HOST_DIR/host.env"; set +a
  API_BASE="${MUSIQ_API_BASE:?MUSIQ_API_BASE missing in host.env}"
  HOST_KEY="${MUSIQ_HOST_API_KEY:?MUSIQ_HOST_API_KEY missing in host.env}"
  BYPASS=()
  [ -n "${MUSIQ_BYPASS:-}" ] && BYPASS=(-H "x-vercel-protection-bypass: ${MUSIQ_BYPASS}")
}

need_root() { [ "$(id -u)" -eq 0 ] || error "Run as root (sudo)."; }

check_deps() {
  for c in curl jq openssl; do command -v "$c" >/dev/null 2>&1 || error "Missing dependency: $c"; done
  local t; t=$(mktemp)
  openssl genpkey -algorithm ed25519 -out "$t" >/dev/null 2>&1 || { rm -f "$t"; error "OpenSSL with Ed25519 support is required (1.1.1+)."; }
  rm -f "$t"
}

valid_id() { [[ "$1" =~ ^[A-Za-z0-9_-]{1,64}$ ]]; }

# ---------------------------------------------------------------- setup
cmd_setup() {
  need_root; check_deps
  mkdir -p "$NODES"; chmod 700 "$HOST_DIR" "$NODES"
  local base="${MUSIQ_API_BASE:-https://musiqnetwork.com}" key="${MUSIQ_HOST_API_KEY:-}"
  if [ -z "$key" ] && [ -f "$HOST_DIR/host.env" ]; then key=$(grep '^MUSIQ_HOST_API_KEY=' "$HOST_DIR/host.env" | cut -d= -f2-); fi
  [ -n "$key" ] || { read -rsp "Host API key (mnh_...): " key; echo; }
  [[ "$key" == mnh_* ]] || error "That doesn't look like a host API key (mnh_...)."
  umask 077
  {
    echo "MUSIQ_API_BASE=$base"
    echo "MUSIQ_HOST_API_KEY=$key"
    [ -n "${MUSIQ_BYPASS:-}" ] && echo "MUSIQ_BYPASS=$MUSIQ_BYPASS"
    echo "MUSIQ_PARALLEL=${MUSIQ_PARALLEL:-16}"
  } > "$HOST_DIR/host.env"
  chmod 600 "$HOST_DIR/host.env"

  install -m 700 "$0" /usr/local/bin/musiq-host
  cat > "/etc/systemd/system/${SERVICE}.service" <<EOF
[Unit]
Description=MusIQ host agent (heartbeats for every node on this server)
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
Environment=MUSIQ_HOST_DIR=$HOST_DIR
ExecStart=/usr/local/bin/musiq-host heartbeat
StandardOutput=journal
StandardError=journal
EOF
  cat > "/etc/systemd/system/${SERVICE}.timer" <<EOF
[Unit]
Description=MusIQ host agent heartbeat timer

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
  load_config
  local code
  code=$(curl -sS -m 20 -o /dev/null -w '%{http_code}' "$API_BASE/api/nodes/v1/licenses?limit=1" \
    -H "X-ACCESS-KEY: $HOST_KEY" "${BYPASS[@]}" || echo 000)
  [ "$code" = "200" ] || error "Setup saved, but the API refused the host key (HTTP $code). Check the key and MUSIQ_API_BASE."
  log "Set up. Add nodes with: musiq-host activate <licenseId>"
}

# ------------------------------------------------------------- activate
activate_one() {
  local id="$1" dir="$NODES/$1"
  valid_id "$id" || { log "$id: not a valid license id"; return 1; }
  mkdir -p "$dir"; chmod 700 "$dir"
  openssl genpkey -algorithm ed25519 -out "$dir/node.key.new" >/dev/null 2>&1
  chmod 600 "$dir/node.key.new"
  local pub body resp code json
  pub=$(openssl pkey -in "$dir/node.key.new" -pubout -outform DER | tail -c 32 | base64 | tr -d '\n')
  body=$(jq -cn --arg id "$id" --arg p "$pub" --arg v "$AGENT_VERSION" '{licenseId:$id, nodePublicKey:$p, agentVersion:$v}')
  resp=$(curl -sS -m 30 -w '\n%{http_code}' -X POST "$API_BASE/api/nodes/v1/activate" \
    -H "Content-Type: application/json" -H "X-ACCESS-KEY: $HOST_KEY" "${BYPASS[@]}" -d "$body" 2>&1) || resp=$'\n000'
  code=$(echo "$resp" | tail -1); json=$(echo "$resp" | sed '$d')
  if [ "$code" != "200" ]; then
    rm -f "$dir/node.key.new"
    [ -f "$dir/node.key" ] || rmdir "$dir" 2>/dev/null || true
    log "$id: activation failed ($code): $(echo "$json" | jq -r '.message // .error' 2>/dev/null || echo "$json")"
    return 1
  fi
  mv "$dir/node.key.new" "$dir/node.key"
  echo "$json" | jq '{licenseId, tokenId, memberId, activatedAt}' > "$dir/info.json"
  log "$id: activated (token #$(echo "$json" | jq -r '.tokenId // "pending"'))."
  beat_one "$id" || true
}

cmd_activate() {
  need_root; load_config
  [ $# -gt 0 ] || error "Usage: $0 activate <licenseId> [...]"
  local failed=0
  for id in "$@"; do activate_one "$id" || failed=$((failed + 1)); done
  [ "$failed" -eq 0 ] || error "$failed activation(s) failed."
}

cmd_activate_file() {
  [ -f "${1:-}" ] || error "Usage: $0 activate-file <file with one license id per line>"
  mapfile -t ids < <(grep -Eo '^[A-Za-z0-9_-]+' "$1")
  cmd_activate "${ids[@]}"
}

# ------------------------------------------------------------ heartbeat
beat_one() {
  local id="$1" key="$NODES/$1/node.key" body msg sig resp code json attempt
  [ -f "$key" ] || { log "$id: no node key"; return 1; }
  for attempt in 1 2 3; do
    body=$(jq -cn --arg id "$id" --argjson ts "$(date +%s)" --arg v "$AGENT_VERSION" '{licenseId:$id, ts:$ts, agentVersion:$v}')
    msg=$(mktemp); printf '%s' "$body" > "$msg"
    sig=$(openssl pkeyutl -sign -inkey "$key" -rawin -in "$msg" | base64 | tr -d '\n'); rm -f "$msg"
    resp=$(curl -sS -m 30 -w '\n%{http_code}' -X POST "$API_BASE/api/nodes/v1/heartbeat" \
      -H "Content-Type: application/json" -H "X-Signature: $sig" "${BYPASS[@]}" -d "$body" 2>&1) || resp=$'\n000'
    code=$(echo "$resp" | tail -1); json=$(echo "$resp" | sed '$d')
    case "$code" in
      200) echo "$(date -u +%FT%TZ) ok day $(echo "$json" | jq -r '.day')" > "$NODES/$id/last"; return 0 ;;
      400|401|403|404|410)
        echo "$(date -u +%FT%TZ) rejected $code $(echo "$json" | jq -r '.error' 2>/dev/null)" > "$NODES/$id/last"
        log "$id: heartbeat rejected ($code): $(echo "$json" | jq -r '.message // .error' 2>/dev/null || echo "$json")"
        return 1 ;;
      *) sleep $((attempt * 10)) ;;
    esac
  done
  echo "$(date -u +%FT%TZ) failed $code" > "$NODES/$id/last"
  log "$id: heartbeat failed after 3 attempts ($code)."
  return 1
}

cmd_heartbeat() {
  load_config
  [ -d "$NODES" ] || { log "No nodes yet."; return 0; }
  local ids total
  ids=$(find "$NODES" -mindepth 2 -maxdepth 2 -name node.key -printf '%h\n' | xargs -r -n1 basename)
  total=$(echo "$ids" | grep -c . || true)
  [ "$total" -gt 0 ] || { log "No nodes yet."; return 0; }
  export -f beat_one log valid_id; export NODES API_BASE AGENT_VERSION
  export BYPASS_HEADER="${MUSIQ_BYPASS:-}"
  local failed
  failed=$(echo "$ids" | xargs -P "${MUSIQ_PARALLEL:-16}" -I{} bash -c \
    'BYPASS=(); [ -n "$BYPASS_HEADER" ] && BYPASS=(-H "x-vercel-protection-bypass: $BYPASS_HEADER"); beat_one "$1" >/dev/null 2>&1 || echo x' _ {} | grep -c x || true)
  log "Heartbeats sent for $total node(s); $((total - failed)) ok, $failed failed."
  [ "$failed" -eq 0 ]
}

# --------------------------------------------------------------- status
cmd_status() {
  [ -d "$NODES" ] || { echo "No nodes."; return 0; }
  printf '%-28s %-8s %s\n' "LICENSE" "TOKEN" "LAST HEARTBEAT"
  for d in "$NODES"/*/; do
    [ -f "$d/node.key" ] || continue
    local id; id=$(basename "$d")
    printf '%-28s %-8s %s\n' "$id" "$(jq -r '.tokenId // "-"' "$d/info.json" 2>/dev/null || echo -)" "$(cat "$d/last" 2>/dev/null || echo never)"
  done
}

cmd_remove() {
  need_root
  [ $# -gt 0 ] || error "Usage: $0 remove <licenseId> [...]"
  for id in "$@"; do
    valid_id "$id" && [ -d "$NODES/$id" ] && rm -rf "${NODES:?}/$id" && log "$id: removed from this server." || log "$id: not on this server."
  done
}

cmd_uninstall() {
  need_root
  systemctl disable --now "${SERVICE}.timer" 2>/dev/null || true
  rm -f "/etc/systemd/system/${SERVICE}.service" "/etc/systemd/system/${SERVICE}.timer" /usr/local/bin/musiq-host
  systemctl daemon-reload
  rm -rf "$HOST_DIR"
  log "Removed. Licenses are unaffected; their nodes stop checking in from this server."
}

case "${1:-}" in
  setup) cmd_setup ;;
  activate) shift; cmd_activate "$@" ;;
  activate-file) shift; cmd_activate_file "$@" ;;
  heartbeat) cmd_heartbeat ;;
  status) cmd_status ;;
  remove) shift; cmd_remove "$@" ;;
  uninstall) cmd_uninstall ;;
  *) sed -n '2,19p' "$0" | sed 's/^# \{0,1\}//'; exit 1 ;;
esac
