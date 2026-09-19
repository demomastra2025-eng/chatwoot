#!/usr/bin/env bash
set -euo pipefail

usage() {
  echo "usage: promote_production.sh <40-char-git-sha> <chatwoot-image@sha256:digest> <voice-image@sha256:digest>" >&2
  exit 64
}

[[ $# -eq 3 ]] || usage
[[ ${EUID} -eq 0 ]] || { echo "must run as root" >&2; exit 77; }

SHA="$1"
APP_IMAGE_REF="$2"
VOICE_IMAGE_REF="$3"
[[ "${SHA}" =~ ^[0-9a-f]{40}$ ]] || usage
[[ "${APP_IMAGE_REF}" =~ ^ghcr\.io/demomastra2025-eng/chatwoot@sha256:[0-9a-f]{64}$ ]] || usage
[[ "${VOICE_IMAGE_REF}" =~ ^ghcr\.io/demomastra2025-eng/onelink-ai-voice@sha256:[0-9a-f]{64}$ ]] || usage

ROOT=/root/crafty
ENV_FILE="${ROOT}/.env.production"
COMPOSE_FILE="${ROOT}/docker-compose.production.yml"
LOCK_FILE="${ROOT}/logs/production-deploy.lock"
case "${DRY_RUN:-false}" in
  true|1|yes) DRY_RUN=true ;;
  false|0|no|'') DRY_RUN=false ;;
  *) echo "DRY_RUN must be true/false or 1/0" >&2; exit 64 ;;
esac
COMPOSE=(docker compose --env-file "${ENV_FILE}" -f "${COMPOSE_FILE}")

log() { printf '[onelink-prod-promote] %s\n' "$*"; }
with_images() {
  CHATWOOT_IMAGE="${APP_IMAGE_REF}" ONELINK_AI_VOICE_IMAGE="${VOICE_IMAGE_REF}" \
    SOURCE_SHA="${SHA}" "${COMPOSE[@]}" "$@"
}

[[ -f "${ENV_FILE}" && -f "${COMPOSE_FILE}" ]] || {
  echo "production compose or env file is missing" >&2
  exit 66
}
mkdir -p "$(dirname "${LOCK_FILE}")"
exec 9>"${LOCK_FILE}"
flock -n 9 || { echo "another production deployment is active" >&2; exit 75; }

log "validating immutable image reference and compose plan"
if [[ "${DRY_RUN}" != true ]]; then
  for image in "${APP_IMAGE_REF}" "${VOICE_IMAGE_REF}"; do
    docker pull "${image}"
    embedded_sha="$(docker run --rm --entrypoint cat "${image}" /app/.git_sha | tr -d '\r\n')"
    [[ "${embedded_sha}" == "${SHA}" ]] || {
      echo "image provenance mismatch for ${image%%@*}: expected ${SHA}, got ${embedded_sha:-missing}" >&2
      exit 65
    }
  done
fi
with_images config --quiet

mapfile -t APP_SERVICES < <(
  with_images config --format json | python3 -c '
import json, sys
config = json.load(sys.stdin)
target = sys.argv[1]
for name, service in sorted(config.get("services", {}).items()):
    if service.get("image") == target:
        print(name)
' "${APP_IMAGE_REF}"
)

contains_service() {
  local expected="$1" service
  for service in "${APP_SERVICES[@]}"; do [[ "${service}" == "${expected}" ]] && return 0; done
  return 1
}
if ! contains_service chatwoot_rails || ! contains_service chatwoot_rails_2; then
  echo "compose plan does not contain both rolling web services" >&2
  exit 65
fi
((${#APP_SERVICES[@]} > 2)) || { echo "no Chatwoot workers selected" >&2; exit 65; }

printf 'sha=%s\napp_image=%s\nvoice_image=%s\nservices=%s\n' \
  "${SHA}" "${APP_IMAGE_REF}" "${VOICE_IMAGE_REF}" "${APP_SERVICES[*]}"
if [[ "${DRY_RUN}" == true ]]; then
  log "DRY_RUN=true: no pull, migration, recreation, env update, or rollback tag"
  exit 0
fi

RAILS_ID="$("${COMPOSE[@]}" ps -q chatwoot_rails)"
[[ -n "${RAILS_ID}" ]] || { echo "chatwoot_rails is not running" >&2; exit 69; }
VOICE_ID="$("${COMPOSE[@]}" ps -q onelink_ai_voice)"
[[ -n "${VOICE_ID}" ]] || { echo "onelink_ai_voice is not running" >&2; exit 69; }
OLD_IMAGE_ID="$(docker inspect -f '{{.Image}}' "${RAILS_ID}")"
OLD_VOICE_IMAGE_ID="$(docker inspect -f '{{.Image}}' "${VOICE_ID}")"
OLD_SHA="$(docker exec "${RAILS_ID}" cat /app/.git_sha 2>/dev/null | tr -d '\r\n')"
[[ "${OLD_SHA}" =~ ^[0-9a-f]{40}$ ]] || { echo "running Chatwoot revision is unprovable" >&2; exit 69; }
OLD_VOICE_SHA="$(docker exec "${VOICE_ID}" cat /app/.git_sha 2>/dev/null | tr -d '\r\n' || true)"
[[ -z "${OLD_VOICE_SHA}" || "${OLD_VOICE_SHA}" =~ ^[0-9a-f]{40}$ ]] || {
  echo "running AI voice revision marker is invalid" >&2
  exit 69
}
CUTOVER_STARTED=false
PROMOTION_SUCCEEDED=false
ROLLBACK_IN_PROGRESS=false
ROLLBACK_STAMP="$(date -u +%Y%m%dT%H%M%SZ)"
ROLLBACK_TAG="onelink-chatwoot-rollback:${ROLLBACK_STAMP}"
VOICE_ROLLBACK_TAG="onelink-ai-voice-rollback:${ROLLBACK_STAMP}"
ENV_BACKUP="${ENV_FILE}.pre-promote.${ROLLBACK_STAMP}.$$"
docker tag "${OLD_IMAGE_ID}" "${ROLLBACK_TAG}"
docker tag "${OLD_VOICE_IMAGE_ID}" "${VOICE_ROLLBACK_TAG}"
cp -a "${ENV_FILE}" "${ENV_BACKUP}"
log "preserved rollback image ${ROLLBACK_TAG} (${OLD_IMAGE_ID})"
log "preserved voice rollback image ${VOICE_ROLLBACK_TAG} (${OLD_VOICE_IMAGE_ID})"

wait_service() {
  local service="$1" timeout="$2" start now cid status health stable=0
  start="$(date +%s)"
  while true; do
    cid="$("${COMPOSE[@]}" ps -q "${service}")"
    if [[ -n "${cid}" ]]; then
      status="$(docker inspect -f '{{.State.Status}}' "${cid}")"
      health="$(docker inspect -f '{{if .State.Health}}{{.State.Health.Status}}{{else}}none{{end}}' "${cid}")"
      if [[ "${status}" == running && "${health}" == none ]]; then
        ((stable += 1))
        ((stable >= 3)) && return 0
      elif [[ "${status}" == running && "${health}" != unhealthy && "${health}" != starting ]]; then
        return 0
      else
        stable=0
      fi
    fi
    now="$(date +%s)"
    (( now - start < timeout )) || return 1
    sleep 2
  done
}

recreate() {
  local app_image="$1" voice_image="$2" service="$3" source_sha="${4:-${SHA}}" timeout=240
  case "${service}" in
    chatwoot_rails|chatwoot_rails_2) timeout=600 ;;
  esac
  CHATWOOT_IMAGE="${app_image}" ONELINK_AI_VOICE_IMAGE="${voice_image}" SOURCE_SHA="${source_sha}" "${COMPOSE[@]}" \
    up -d --no-deps --no-build --force-recreate "${service}"
  wait_service "${service}" "${timeout}"
}

voice_readiness() {
  local voice_id="$1"
  docker exec "${voice_id}" sh -lc 'wget -qO- "http://127.0.0.1:${VOICE_AGENT_API_PORT:-8081}/ready"' |
    python3 -c 'import json, sys; json.load(sys.stdin)'
}

restore_app_service() {
  local service="$1" cid running_sha="" running_image=""
  cid="$("${COMPOSE[@]}" ps -q "${service}" 2>/dev/null || true)"
  if [[ -n "${cid}" ]]; then
    running_sha="$(docker exec "${cid}" cat /app/.git_sha 2>/dev/null | tr -d '\r\n' || true)"
    running_image="$(docker inspect -f '{{.Image}}' "${cid}" 2>/dev/null || true)"
  fi
  if [[ "${running_sha}" != "${OLD_SHA}" || "${running_image}" != "${OLD_IMAGE_ID}" ]]; then
    recreate "${ROLLBACK_TAG}" "${VOICE_ROLLBACK_TAG}" "${service}" "${OLD_SHA}"
  else
    wait_service "${service}" 600
  fi
}

rollback() {
  local reason="$1" service cid running_sha running_image voice_sha rollback_failed=false
  ROLLBACK_IN_PROGRESS=true
  trap - EXIT HUP INT TERM
  set +e
  echo "production verification failed: ${reason}; rolling back" >&2

  # Restore the durable image references before best-effort runtime recovery.
  # Docker inspection/recreation failures below must not skip this step.
  if cp -a "${ENV_BACKUP}" "${ENV_FILE}"; then
    rm -f "${ENV_BACKUP}"
  else
    echo "rollback mismatch: failed to restore ${ENV_FILE}" >&2
    rollback_failed=true
  fi

  for service in "${APP_SERVICES[@]}"; do
    case "${service}" in chatwoot_rails|chatwoot_rails_2) continue ;; esac
    restore_app_service "${service}" || rollback_failed=true
  done
  restore_app_service chatwoot_rails_2 || rollback_failed=true
  restore_app_service chatwoot_rails || rollback_failed=true

  cid="$("${COMPOSE[@]}" ps -q onelink_ai_voice 2>/dev/null || true)"
  running_image=""
  [[ -n "${cid}" ]] && running_image="$(docker inspect -f '{{.Image}}' "${cid}" 2>/dev/null || true)"
  if [[ "${running_image}" != "${OLD_VOICE_IMAGE_ID}" ]]; then
    recreate "${ROLLBACK_TAG}" "${VOICE_ROLLBACK_TAG}" onelink_ai_voice "${OLD_SHA}" || rollback_failed=true
  else
    wait_service onelink_ai_voice 240 || rollback_failed=true
  fi

  for service in "${APP_SERVICES[@]}"; do
    cid="$("${COMPOSE[@]}" ps -q "${service}" 2>/dev/null || true)"
    running_sha=""
    running_image=""
    if [[ -n "${cid}" ]]; then
      running_sha="$(docker exec "${cid}" cat /app/.git_sha 2>/dev/null | tr -d '\r\n' || true)"
      running_image="$(docker inspect -f '{{.Image}}' "${cid}" 2>/dev/null || true)"
    fi
    if [[ "${running_sha}" != "${OLD_SHA}" || "${running_image}" != "${OLD_IMAGE_ID}" ]]; then
      echo "rollback mismatch: ${service} revision/image is not the preserved runtime" >&2
      rollback_failed=true
    fi
  done
  cid="$("${COMPOSE[@]}" ps -q onelink_ai_voice 2>/dev/null || true)"
  voice_sha=""
  [[ -n "${cid}" ]] && voice_sha="$(docker exec "${cid}" cat /app/.git_sha 2>/dev/null | tr -d '\r\n' || true)"
  if [[ -z "${cid}" || "$(docker inspect -f '{{.Image}}' "${cid}" 2>/dev/null || true)" != "${OLD_VOICE_IMAGE_ID}" || \
    ( -n "${OLD_VOICE_SHA}" && "${voice_sha}" != "${OLD_VOICE_SHA}" ) ]] || ! voice_readiness "${cid}"; then
    echo "rollback mismatch: onelink_ai_voice did not restore ${OLD_VOICE_IMAGE_ID}" >&2
    rollback_failed=true
  fi
  [[ "${rollback_failed}" == false ]] || echo "rollback verification failed; operator intervention required" >&2
  exit 1
}

on_exit() {
  local status=$?
  trap - EXIT HUP INT TERM
  if [[ "${status}" -ne 0 && "${CUTOVER_STARTED}" == true && "${PROMOTION_SUCCEEDED}" == false && \
    "${ROLLBACK_IN_PROGRESS}" == false ]]; then
    rollback "unexpected deploy process exit status=${status}"
  fi
  exit "${status}"
}
trap on_exit EXIT
trap 'exit 129' HUP
trap 'exit 130' INT
trap 'exit 143' TERM

voice_activity() {
  docker exec "${VOICE_ID}" sh -lc 'wget -qO- "http://127.0.0.1:${VOICE_AGENT_API_PORT:-8081}/ready"' |
    python3 -c '
import json, sys
payload = json.load(sys.stdin)
runtime = payload.get("janus_server_runtime") or {}
print(max(int(payload.get("sessions") or 0), int(runtime.get("active_calls") or 0)))
'
}

log "waiting for the AI voice runtime to become idle"
idle_deadline=$((SECONDS + 300))
while true; do
  active_voice_sessions="$(voice_activity 2>/dev/null || true)"
  [[ "${active_voice_sessions}" =~ ^[0-9]+$ ]] || {
    echo "AI voice readiness payload is unavailable or invalid" >&2
    exit 69
  }
  ((active_voice_sessions == 0)) && break
  ((SECONDS < idle_deadline)) || {
    echo "AI voice runtime still has ${active_voice_sessions} active session(s); refusing rollout" >&2
    exit 75
  }
  sleep 5
done

log "running expand-compatible database preparation with the target image"
if ! with_images run --rm --no-deps chatwoot_rails bundle exec rails db:chatwoot_prepare; then
  echo "database preparation failed before rollout; running services were not changed" >&2
  exit 1
fi

log "recreating workers before rolling web cutover"
CUTOVER_STARTED=true
for service in "${APP_SERVICES[@]}"; do
  case "${service}" in chatwoot_rails|chatwoot_rails_2) continue ;; esac
  recreate "${APP_IMAGE_REF}" "${VOICE_IMAGE_REF}" "${service}" || rollback "${service} did not become ready"
done
recreate "${APP_IMAGE_REF}" "${VOICE_IMAGE_REF}" chatwoot_rails_2 || rollback "chatwoot_rails_2 did not become healthy"
recreate "${APP_IMAGE_REF}" "${VOICE_IMAGE_REF}" chatwoot_rails || rollback "chatwoot_rails did not become healthy"
active_voice_sessions="$(voice_activity 2>/dev/null || true)"
[[ "${active_voice_sessions}" == 0 ]] || rollback "AI voice runtime became busy before cutover"
recreate "${APP_IMAGE_REF}" "${VOICE_IMAGE_REF}" onelink_ai_voice || rollback "onelink_ai_voice did not become healthy"

for service in "${APP_SERVICES[@]}"; do
  if ! cid="$("${COMPOSE[@]}" ps -q "${service}")" || [[ -z "${cid}" ]]; then
    rollback "${service} has no running container"
  fi
  if ! running_sha="$(docker exec "${cid}" cat /app/.git_sha 2>/dev/null | tr -d '\r\n')"; then
    rollback "${service} revision cannot be read"
  fi
  [[ "${running_sha}" == "${SHA}" ]] || rollback "${service} runs ${running_sha:-unknown}"
done

VOICE_ID="$("${COMPOSE[@]}" ps -q onelink_ai_voice)"
VOICE_SHA="$(docker exec "${VOICE_ID}" cat /app/.git_sha 2>/dev/null | tr -d '\r\n' || true)"
[[ "${VOICE_SHA}" == "${SHA}" ]] || rollback "onelink_ai_voice runs ${VOICE_SHA:-unknown}"

log "running idempotent post-deploy finalizers after all runtimes match"
with_images exec -T chatwoot_rails \
  bundle exec rails runner script/onelink/finalize_release.rb || rollback "post-deploy finalizers"

persist_image_refs() {
  python3 - "${ENV_FILE}" "${APP_IMAGE_REF}" "${VOICE_IMAGE_REF}" <<'PY'
from pathlib import Path
import os
import sys

path = Path(sys.argv[1])
values = {
    "CHATWOOT_IMAGE": sys.argv[2],
    "ONELINK_AI_VOICE_IMAGE": sys.argv[3],
}
lines = path.read_text(encoding="utf-8").splitlines()
out = []
written = set()
for line in lines:
    key = line.split("=", 1)[0]
    if key in values:
        if key not in written:
            out.append(f"{key}={values[key]}")
            written.add(key)
        continue
    out.append(line)
for key, value in values.items():
    if key not in written:
        out.append(f"{key}={value}")
temporary = path.with_suffix(path.suffix + ".tmp")
temporary.write_text("\n".join(out) + "\n", encoding="utf-8")
os.chmod(temporary, path.stat().st_mode & 0o777)
os.replace(temporary, path)
PY
}

persist_image_refs || rollback "persisting immutable image references"

PROMOTION_SUCCEEDED=true
trap - EXIT HUP INT TERM
rm -f "${ENV_BACKUP}"
log "production promotion complete sha=${SHA} app_image=${APP_IMAGE_REF} voice_image=${VOICE_IMAGE_REF}"
