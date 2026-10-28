#!/usr/bin/env bash
# MusIQ Node agent: sends one signed heartbeat to the MusIQ node API.
# Run by the musiq-agent systemd timer (see install.sh). Safe to run any time:
# the network counts at most one heartbeat per license per day.
set -euo pipefail

AGENT_VERSION="1.0.0"
AGENT_DIR="${MUSIQ_AGENT_DIR:-/opt/musiq-agent}"
API_BASE="${MUSIQ_API_BASE:?MUSIQ_API_BASE is not set (see $AGENT_DIR/agent.env)}"
LICENSE_ID="${MUSIQ_LICENSE_ID:?MUSIQ_LICENSE_ID is not set (see $AGENT_DIR/agent.env)}"
KEY="$AGENT_DIR/node.key"

log() { echo "[$(date -u '+%Y-%m-%dT%H:%M:%SZ')] [musiq-agent] $*"; }

[ -f "$KEY" ] || { log "No node key at $KEY — run the installer."; exit 1; }

BYPASS=()
[ -n "${MUSIQ_BYPASS:-}" ] && BYPASS=(-H "x-vercel-protection-bypass: ${MUSIQ_BYPASS}")

for attempt in 1 2 3 4 5; do
  # The exact bytes of BODY are what gets signed (Ed25519, raw message).
  BODY=$(jq -cn --arg id "$LICENSE_ID" --argjson ts "$(date +%s)" --arg v "$AGENT_VERSION" \
    '{licenseId:$id, ts:$ts, agentVersion:$v}')
  MSG=$(mktemp)
  printf '%s' "$BODY" > "$MSG"
  SIG=$(openssl pkeyutl -sign -inkey "$KEY" -rawin -in "$MSG" | base64 | tr -d '\n')
  rm -f "$MSG"

  RESP=$(curl -sS -m 30 -w '\n%{http_code}' -X POST "$API_BASE/api/nodes/v1/heartbeat" \
    -H "Content-Type: application/json" -H "X-Signature: $SIG" "${BYPASS[@]}" -d "$BODY" 2>&1) || RESP=$'\n000'
  CODE=$(echo "$RESP" | tail -1)
  JSON=$(echo "$RESP" | sed '$d')

  case "$CODE" in
    200)
      if [ "$(echo "$JSON" | jq -r '.recorded')" = "true" ]; then
        log "Heartbeat recorded for day $(echo "$JSON" | jq -r '.day')."
      else
        log "Heartbeat received (day $(echo "$JSON" | jq -r '.day') already recorded)."
      fi
      exit 0 ;;
    400|401|403|404|410)
      # Not retryable: wrong key, revoked license, not activated, etc.
      log "Heartbeat rejected ($CODE): $(echo "$JSON" | jq -r '.message // .error' 2>/dev/null || echo "$JSON")"
      exit 1 ;;
    *)
      log "Heartbeat attempt $attempt failed ($CODE); retrying..."
      sleep $(( attempt * 30 )) ;;
  esac
done
log "Heartbeat failed after 5 attempts; the timer will try again later."
exit 1
