#!/usr/bin/env bash
set -euo pipefail

PROXY_URL="${SIMDECK_PROXY_URL%/}"
PORT="${SIMDECK_RUNNER_PORT:-4310}"
RUNNER_TOKEN="${SIMDECK_PROXY_RUNNER_TOKEN:-}"

if [[ -z "$PROXY_URL" ]]; then
  echo "SIMDECK_PROXY_URL is required" >&2
  exit 1
fi

if [[ -z "$RUNNER_TOKEN" ]]; then
  echo "SIMDECK_PROXY_RUNNER_TOKEN repo secret is required" >&2
  exit 1
fi

post_json() {
  local path="$1"
  local body="$2"
  curl --fail-with-body --silent --show-error \
    -X POST \
    -H "content-type: application/json" \
    -H "x-simdeck-token: ${RUNNER_TOKEN}" \
    --data "${body}" \
    "${PROXY_URL}${path}"
}

post_json "/api/runner/heartbeat" "{\"message\":\"Installing SimDeck on macOS runner...\",\"runId\":\"${GH_RUN_ID:-}\",\"runUrl\":\"${GH_RUN_URL:-}\"}" >/dev/null

npm i -g simdeck@latest

post_json "/api/runner/heartbeat" "{\"message\":\"Starting SimDeck service...\",\"runId\":\"${GH_RUN_ID:-}\",\"runUrl\":\"${GH_RUN_URL:-}\"}" >/dev/null

PAIR_JSON="$(simdeck pair --port "${PORT}" --bind 127.0.0.1 --json)"
echo "${PAIR_JSON}" | jq '{ok, url, serverId, target, started, addresses}'

LOCAL_SIMDECK_URL="$(echo "${PAIR_JSON}" | jq -r '.url // "http://127.0.0.1:'"${PORT}"'"')"
PAIRING_CODE="$(echo "${PAIR_JSON}" | jq -r '.pairingCode // empty')"
if [[ -z "$PAIRING_CODE" ]]; then
  echo "simdeck pair --json did not include pairingCode" >&2
  exit 1
fi
PAIR_RESPONSE="$(curl --fail-with-body --silent --show-error \
  -H "accept: application/json" \
  -H "content-type: application/json" \
  --data "{\"code\":\"${PAIRING_CODE}\"}" \
  "${LOCAL_SIMDECK_URL%/}/api/pair")"
SIMDECK_TOKEN="$(echo "${PAIR_RESPONSE}" | jq -r '.accessToken // empty')"
if [[ -z "$SIMDECK_TOKEN" ]]; then
  echo "SimDeck pairing did not return accessToken" >&2
  exit 1
fi

post_json "/api/runner/heartbeat" "{\"message\":\"Opening Cloudflare tunnel...\",\"runId\":\"${GH_RUN_ID:-}\",\"runUrl\":\"${GH_RUN_URL:-}\"}" >/dev/null

if ! command -v cloudflared >/dev/null 2>&1; then
  brew install cloudflared
fi

TUNNEL_LOG=""
TUNNEL_PID=""
TUNNEL_URL=""

cleanup() {
  if [[ -n "${TUNNEL_PID}" ]]; then
    kill "${TUNNEL_PID}" >/dev/null 2>&1 || true
  fi
  simdeck kill >/dev/null 2>&1 || true
}
trap cleanup EXIT

register_tunnel() {
  local register_body
  register_body="$(jq -nc \
    --arg baseUrl "$TUNNEL_URL" \
    --arg simdeckToken "$SIMDECK_TOKEN" \
    --arg runId "${GH_RUN_ID:-}" \
    --arg runUrl "${GH_RUN_URL:-}" \
    '{baseUrl:$baseUrl, simdeckToken:$simdeckToken, runId:$runId, runUrl:$runUrl}')"
  post_json "/api/runner/register" "${register_body}" >/dev/null
}

start_tunnel() {
  if [[ -n "${TUNNEL_PID}" ]]; then
    kill "${TUNNEL_PID}" >/dev/null 2>&1 || true
  fi
  TUNNEL_LOG="$(mktemp)"
  cloudflared tunnel --url "http://127.0.0.1:${PORT}" --protocol http2 --no-autoupdate >"${TUNNEL_LOG}" 2>&1 &
  TUNNEL_PID="$!"
  TUNNEL_URL=""
  for _ in $(seq 1 60); do
    if ! kill -0 "${TUNNEL_PID}" >/dev/null 2>&1; then
      cat "${TUNNEL_LOG}" >&2
      return 1
    fi
    TUNNEL_URL="$(grep -Eo 'https://[-a-zA-Z0-9]+\.trycloudflare\.com' "${TUNNEL_LOG}" | tail -n 1 || true)"
    if [[ -n "$TUNNEL_URL" ]]; then
      register_tunnel
      echo "SimDeck runner registered at ${TUNNEL_URL}"
      return 0
    fi
    sleep 1
  done
  cat "${TUNNEL_LOG}" >&2
  return 1
}

ensure_tunnel_healthy() {
  if [[ -z "${TUNNEL_URL}" ]] || ! kill -0 "${TUNNEL_PID}" >/dev/null 2>&1; then
    return 1
  fi
  curl --fail --silent --show-error --max-time 8 \
    -H "accept: application/json" \
    -H "x-simdeck-token: ${SIMDECK_TOKEN}" \
    "${TUNNEL_URL}/api/health" >/dev/null
}

if ! start_tunnel; then
  post_json "/api/runner/heartbeat" "{\"message\":\"Cloudflare tunnel failed to start.\",\"runId\":\"${GH_RUN_ID:-}\",\"runUrl\":\"${GH_RUN_URL:-}\"}" >/dev/null || true
  exit 1
fi

while true; do
  if ! ensure_tunnel_healthy; then
    post_json "/api/runner/heartbeat" "{\"message\":\"Tunnel disconnected. Reopening...\",\"runId\":\"${GH_RUN_ID:-}\",\"runUrl\":\"${GH_RUN_URL:-}\"}" >/dev/null || true
    start_tunnel || exit 1
  fi
  KEEPALIVE="$(post_json "/api/runner/keepalive" "{}")"
  SHOULD_STOP="$(echo "${KEEPALIVE}" | jq -r '.shouldStop')"
  SHOULD_REOPEN_TUNNEL="$(echo "${KEEPALIVE}" | jq -r '.shouldReopenTunnel')"
  IDLE_FOR="$(echo "${KEEPALIVE}" | jq -r '.idleForSeconds')"
  echo "SimDeck keepalive: idle ${IDLE_FOR}s, shouldStop=${SHOULD_STOP}, shouldReopenTunnel=${SHOULD_REOPEN_TUNNEL}"
  if [[ "$SHOULD_STOP" == "true" ]]; then
    break
  fi
  if [[ "$SHOULD_REOPEN_TUNNEL" == "true" ]]; then
    post_json "/api/runner/heartbeat" "{\"message\":\"Tunnel disconnected. Reopening...\",\"runId\":\"${GH_RUN_ID:-}\",\"runUrl\":\"${GH_RUN_URL:-}\"}" >/dev/null || true
    start_tunnel || exit 1
  fi
  sleep 15
done
