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
echo "${PAIR_JSON}" | jq .

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

TUNNEL_LOG="$(mktemp)"
cloudflared tunnel --url "http://127.0.0.1:${PORT}" --no-autoupdate >"${TUNNEL_LOG}" 2>&1 &
TUNNEL_PID="$!"

cleanup() {
  kill "${TUNNEL_PID}" >/dev/null 2>&1 || true
  simdeck kill >/dev/null 2>&1 || true
}
trap cleanup EXIT

TUNNEL_URL=""
for _ in $(seq 1 60); do
  TUNNEL_URL="$(grep -Eo 'https://[-a-zA-Z0-9]+\.trycloudflare\.com' "${TUNNEL_LOG}" | tail -n 1 || true)"
  if [[ -n "$TUNNEL_URL" ]]; then
    break
  fi
  sleep 1
done

if [[ -z "$TUNNEL_URL" ]]; then
  cat "${TUNNEL_LOG}" >&2
  post_json "/api/runner/heartbeat" "{\"message\":\"Cloudflare tunnel failed to start.\",\"runId\":\"${GH_RUN_ID:-}\",\"runUrl\":\"${GH_RUN_URL:-}\"}" >/dev/null || true
  exit 1
fi

REGISTER_BODY="$(jq -nc \
  --arg baseUrl "$TUNNEL_URL" \
  --arg simdeckToken "$SIMDECK_TOKEN" \
  --arg runId "${GH_RUN_ID:-}" \
  --arg runUrl "${GH_RUN_URL:-}" \
  '{baseUrl:$baseUrl, simdeckToken:$simdeckToken, runId:$runId, runUrl:$runUrl}')"
post_json "/api/runner/register" "${REGISTER_BODY}" >/dev/null

echo "SimDeck runner registered at ${TUNNEL_URL}"

while true; do
  KEEPALIVE="$(post_json "/api/runner/keepalive" "{}")"
  SHOULD_STOP="$(echo "${KEEPALIVE}" | jq -r '.shouldStop')"
  IDLE_FOR="$(echo "${KEEPALIVE}" | jq -r '.idleForSeconds')"
  echo "SimDeck keepalive: idle ${IDLE_FOR}s, shouldStop=${SHOULD_STOP}"
  if [[ "$SHOULD_STOP" == "true" ]]; then
    break
  fi
  sleep 15
done
