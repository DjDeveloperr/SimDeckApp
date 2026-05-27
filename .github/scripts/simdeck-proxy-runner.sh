#!/usr/bin/env bash
set -euo pipefail

PROXY_URL="${SIMDECK_PROXY_URL%/}"
PORT="${SIMDECK_RUNNER_PORT:-4310}"
RUNNER_TOKEN="${SIMDECK_PROXY_RUNNER_TOKEN:-}"
DEFAULT_BOOT_SIMULATOR_NAME="${SIMDECK_DEFAULT_BOOT_SIMULATOR_NAME:-iPhone 17 Pro}"

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
    --max-time 20 \
    -X POST \
    -H "content-type: application/json" \
    -H "x-simdeck-token: ${RUNNER_TOKEN}" \
    --data "${body}" \
    "${PROXY_URL}${path}"
}

runner_heartbeat() {
  local message="$1"
  local reconnecting="${2:-false}"
  local body
  body="$(jq -nc \
    --arg message "${message}" \
    --arg runId "${GH_RUN_ID:-}" \
    --arg runUrl "${GH_RUN_URL:-}" \
    --argjson reconnecting "${reconnecting}" \
    '{message:$message, runId:$runId, runUrl:$runUrl} + (if $reconnecting then {reconnecting:true} else {} end)')"
  post_json "/api/runner/heartbeat" "${body}" >/dev/null || true
}

local_simdeck_request() {
  local method="$1"
  local path="$2"
  local max_time="${3:-300}"
  curl --fail-with-body --silent --show-error \
    --max-time "${max_time}" \
    -X "${method}" \
    -H "accept: application/json" \
    -H "x-simdeck-token: ${SIMDECK_TOKEN}" \
    "${LOCAL_SIMDECK_URL%/}${path}"
}

runner_heartbeat "Installing SimDeck CLI on macOS runner..."

npm i -g simdeck@latest

runner_heartbeat "Starting SimDeck service..."

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

boot_default_simulator() {
  local list_json booted_udid target_udid simulator_count encoded_name
  encoded_name="$(jq -rn --arg value "$DEFAULT_BOOT_SIMULATOR_NAME" '$value|@uri')"
  runner_heartbeat "Finding ${DEFAULT_BOOT_SIMULATOR_NAME}..."

  for attempt in $(seq 1 60); do
    list_json="$(local_simdeck_request GET "/api/simulators" || echo '{"simulators":[]}')"
    simulator_count="$(echo "${list_json}" | jq -r '.simulators | length // 0')"
    booted_udid="$(echo "${list_json}" | jq -r --arg name "$DEFAULT_BOOT_SIMULATOR_NAME" '[.simulators[]? | select(.name == $name and ((.isBooted // false) == true)) | .udid][0] // empty')"
    if [[ -n "$booted_udid" ]]; then
      echo "${DEFAULT_BOOT_SIMULATOR_NAME} already booted: ${booted_udid}"
      return 0
    fi

    target_udid="$(echo "${list_json}" | jq -r --arg name "$DEFAULT_BOOT_SIMULATOR_NAME" '
      [.simulators[]?
        | select(.name == $name)
        | select((.platform // "iOS") == "iOS")
        | select((.isBooted // false) == false)
        | .udid][0] // empty
    ')"
    if [[ -z "$target_udid" ]]; then
      target_udid="$(echo "${list_json}" | jq -r '
      [.simulators[]?
        | select((.name // "") | test("^iPhone 17"))
        | select((.platform // "iOS") == "iOS")
        | select((.isBooted // false) == false)
        | .udid][0] // empty
      ')"
    fi
    if [[ -n "$target_udid" ]]; then
      break
    fi
    runner_heartbeat "Waiting for simulator inventory... (${simulator_count} found)"
    echo "Waiting for simulator inventory; attempt ${attempt}, count=${simulator_count}"
    sleep 2
  done

  if [[ -z "$target_udid" ]]; then
    echo "No ${DEFAULT_BOOT_SIMULATOR_NAME} simulator found; skipping default boot" >&2
    return 0
  fi

  echo "Starting boot for ${DEFAULT_BOOT_SIMULATOR_NAME}: ${target_udid} (${encoded_name})"
  runner_heartbeat "Booting ${DEFAULT_BOOT_SIMULATOR_NAME}..."
  if ! xcrun simctl boot "${target_udid}" >/dev/null 2>&1; then
    runner_heartbeat "Boot request sent through SimDeck service..."
    local_simdeck_request POST "/api/simulators/${target_udid}/boot" 30 >/dev/null || true
  fi
}

if ! boot_default_simulator; then
  runner_heartbeat "Default simulator boot failed. Continuing to tunnel..."
fi

runner_heartbeat "Checking Cloudflare tunnel binary..."

if ! command -v cloudflared >/dev/null 2>&1; then
  runner_heartbeat "Installing Cloudflare tunnel binary..."
  brew install cloudflared
  runner_heartbeat "Cloudflare tunnel binary installed."
else
  runner_heartbeat "Cloudflare tunnel binary ready."
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

wait_for_tunnel_reachable() {
  for attempt in $(seq 1 6); do
    runner_heartbeat "Checking Cloudflare tunnel reachability... (attempt ${attempt})"
    if curl --fail --silent --show-error --max-time 8 \
      -H "accept: application/json" \
      -H "x-simdeck-token: ${SIMDECK_TOKEN}" \
      "${TUNNEL_URL}/api/health" >/dev/null; then
      return 0
    fi
    runner_heartbeat "Cloudflare tunnel URL is not reachable yet."
    sleep 2
  done
  return 1
}

start_tunnel() {
  if [[ -n "${TUNNEL_PID}" ]]; then
    kill "${TUNNEL_PID}" >/dev/null 2>&1 || true
  fi
  runner_heartbeat "Starting Cloudflare tunnel process..."
  TUNNEL_LOG="$(mktemp)"
  cloudflared tunnel --url "http://127.0.0.1:${PORT}" --protocol http2 --no-autoupdate >"${TUNNEL_LOG}" 2>&1 &
  TUNNEL_PID="$!"
  TUNNEL_URL=""
  for attempt in $(seq 1 60); do
    if ! kill -0 "${TUNNEL_PID}" >/dev/null 2>&1; then
      runner_heartbeat "Cloudflare tunnel process exited. Retrying..." true
      cat "${TUNNEL_LOG}" >&2
      return 1
    fi
    TUNNEL_URL="$(grep -Eo 'https://[-a-zA-Z0-9]+\.trycloudflare\.com' "${TUNNEL_LOG}" | tail -n 1 || true)"
    if [[ -n "$TUNNEL_URL" ]]; then
      runner_heartbeat "Cloudflare tunnel URL allocated. Verifying reachability..."
      if ! wait_for_tunnel_reachable; then
        runner_heartbeat "Allocated tunnel URL was not reachable. Requesting a new URL..." true
        return 1
      fi
      runner_heartbeat "Cloudflare tunnel reachable. Registering..."
      for register_attempt in $(seq 1 3); do
        runner_heartbeat "Registering Cloudflare tunnel... (attempt ${register_attempt})"
        if register_tunnel; then
          echo "SimDeck runner registered at ${TUNNEL_URL}"
          return 0
        fi
        runner_heartbeat "Cloudflare tunnel registration failed. Retrying..." true
        echo "Tunnel registration failed; attempt ${register_attempt}" >&2
        sleep 2
      done
      cat "${TUNNEL_LOG}" >&2
      return 1
    fi
    if [[ "$attempt" == "1" || $((attempt % 10)) == "0" ]]; then
      runner_heartbeat "Waiting for Cloudflare tunnel URL... (${attempt}s)"
    fi
    sleep 1
  done
  runner_heartbeat "Timed out waiting for Cloudflare tunnel URL. Retrying..." true
  cat "${TUNNEL_LOG}" >&2
  return 1
}

ensure_tunnel_healthy() {
  if [[ -z "${TUNNEL_URL}" ]] || ! kill -0 "${TUNNEL_PID}" >/dev/null 2>&1; then
    return 1
  fi
  for _ in 1 2; do
    if curl --fail --silent --show-error --max-time 8 \
      -H "accept: application/json" \
      -H "x-simdeck-token: ${SIMDECK_TOKEN}" \
      "${TUNNEL_URL}/api/health" >/dev/null; then
      return 0
    fi
    sleep 2
  done
  return 1
}

start_tunnel_until_registered() {
  local reason="$1"
  local attempt=0 keepalive should_stop delay
  while true; do
    attempt=$((attempt + 1))
    if start_tunnel; then
      return 0
    fi
    runner_heartbeat "${reason} Retrying tunnel in a moment..." true
    if keepalive="$(post_json "/api/runner/keepalive" "{\"runId\":\"${GH_RUN_ID:-}\",\"runUrl\":\"${GH_RUN_URL:-}\"}" 2>/dev/null)"; then
      should_stop="$(echo "${keepalive}" | jq -r '.shouldStop // false')"
      if [[ "${should_stop}" == "true" ]]; then
        return 1
      fi
    fi
    delay=$((attempt < 5 ? attempt * 3 : 15))
    sleep "${delay}"
  done
}

if ! start_tunnel_until_registered "Opening Cloudflare tunnel failed."; then
  exit 0
fi

while true; do
  if ! ensure_tunnel_healthy; then
    runner_heartbeat "Tunnel health check failed. Reopening..." true
    start_tunnel_until_registered "Tunnel disconnected." || break
  fi
  if ! KEEPALIVE="$(post_json "/api/runner/keepalive" "{\"runId\":\"${GH_RUN_ID:-}\",\"runUrl\":\"${GH_RUN_URL:-}\"}")"; then
    echo "SimDeck keepalive failed; retrying after tunnel health check" >&2
    if ! ensure_tunnel_healthy; then
      runner_heartbeat "Worker keepalive failed and tunnel is unhealthy. Reopening..." true
      start_tunnel_until_registered "Tunnel disconnected." || break
    fi
    sleep 15
    continue
  fi
  SHOULD_STOP="$(echo "${KEEPALIVE}" | jq -r '.shouldStop')"
  SHOULD_REOPEN_TUNNEL="$(echo "${KEEPALIVE}" | jq -r '.shouldReopenTunnel')"
  IDLE_FOR="$(echo "${KEEPALIVE}" | jq -r '.idleForSeconds')"
  echo "SimDeck keepalive: idle ${IDLE_FOR}s, shouldStop=${SHOULD_STOP}, shouldReopenTunnel=${SHOULD_REOPEN_TUNNEL}"
  if [[ "$SHOULD_STOP" == "true" ]]; then
    break
  fi
  if [[ "$SHOULD_REOPEN_TUNNEL" == "true" ]]; then
    runner_heartbeat "Worker requested a fresh tunnel. Reopening..." true
    start_tunnel_until_registered "Tunnel disconnected." || break
  fi
  sleep 15
done
