#!/usr/bin/env bash
set -euo pipefail

usage() {
  echo "usage: promote_production.sh <40-char-git-sha> <ghcr-image@sha256:digest>" >&2
  exit 64
}

[[ $# -eq 2 ]] || usage
[[ ${EUID} -eq 0 ]] || { echo "must run as root" >&2; exit 77; }

SHA="$1"
IMAGE_REF="$2"
[[ "${SHA}" =~ ^[0-9a-f]{40}$ ]] || usage
[[ "${IMAGE_REF}" =~ ^ghcr\.io/demomastra2025-eng/chatwoot@sha256:[0-9a-f]{64}$ ]] || usage

ROOT=/root/crafty
ENV_FILE="${ROOT}/.env.production"
COMPOSE_FILE="${ROOT}/docker-compose.production.yml"
LOCK_FILE="${ROOT}/logs/production-deploy.lock"
DRY_RUN="${DRY_RUN:-false}"
COMPOSE=(docker compose --env-file "${ENV_FILE}" -f "${COMPOSE_FILE}")

log() { printf '[onelink-prod-promote] %s\n' "$*"; }
with_image() { CHATWOOT_IMAGE="${IMAGE_REF}" SOURCE_SHA="${SHA}" "${COMPOSE[@]}" "$@"; }

[[ -f "${ENV_FILE}" && -f "${COMPOSE_FILE}" ]] || {
  echo "production compose or env file is missing" >&2
  exit 66
}
mkdir -p "$(dirname "${LOCK_FILE}")"
exec 9>"${LOCK_FILE}"
flock -n 9 || { echo "another production deployment is active" >&2; exit 75; }

log "validating immutable image reference and compose plan"
if [[ "${DRY_RUN}" != true ]]; then
  docker pull "${IMAGE_REF}"
  EMBEDDED_SHA="$(docker run --rm --entrypoint cat "${IMAGE_REF}" /app/.git_sha | tr -d '\r\n')"
  [[ "${EMBEDDED_SHA}" == "${SHA}" ]] || {
    echo "image provenance mismatch: expected ${SHA}, got ${EMBEDDED_SHA:-missing}" >&2
    exit 65
  }
fi
with_image config --quiet

mapfile -t APP_SERVICES < <(
  with_image config --format json | python3 -c '
import json, sys
config = json.load(sys.stdin)
target = sys.argv[1]
for name, service in sorted(config.get("services", {}).items()):
    if service.get("image") == target:
        print(name)
' "${IMAGE_REF}"
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

printf 'sha=%s\nimage=%s\nservices=%s\n' "${SHA}" "${IMAGE_REF}" "${APP_SERVICES[*]}"
if [[ "${DRY_RUN}" == true ]]; then
  log "DRY_RUN=true: no pull, migration, recreation, env update, or rollback tag"
  exit 0
fi

RAILS_ID="$("${COMPOSE[@]}" ps -q chatwoot_rails)"
[[ -n "${RAILS_ID}" ]] || { echo "chatwoot_rails is not running" >&2; exit 69; }
OLD_IMAGE_ID="$(docker inspect -f '{{.Image}}' "${RAILS_ID}")"
OLD_SHA="$(docker exec "${RAILS_ID}" cat /app/.git_sha 2>/dev/null | tr -d '\r\n')"
[[ "${OLD_SHA}" =~ ^[0-9a-f]{40}$ ]] || { echo "running Chatwoot revision is unprovable" >&2; exit 69; }
ROLLBACK_TAG="onelink-chatwoot-rollback:$(date -u +%Y%m%dT%H%M%SZ)"
docker tag "${OLD_IMAGE_ID}" "${ROLLBACK_TAG}"
log "preserved rollback image ${ROLLBACK_TAG} (${OLD_IMAGE_ID})"

wait_service() {
  local service="$1" timeout="$2" start now cid status health stable=0
  start="$(date +%s)"
  while true; do
    cid="$(with_image ps -q "${service}")"
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
  local image="$1" service="$2" source_sha="${3:-${SHA}}" timeout=240
  case "${service}" in
    chatwoot_rails|chatwoot_rails_2) timeout=600 ;;
  esac
  CHATWOOT_IMAGE="${image}" SOURCE_SHA="${source_sha}" "${COMPOSE[@]}" \
    up -d --no-deps --no-build --force-recreate "${service}"
  wait_service "${service}" "${timeout}"
}

rollback() {
  local reason="$1" service cid running_sha rollback_failed=false
  echo "production verification failed: ${reason}; rolling back" >&2
  for service in "${APP_SERVICES[@]}"; do
    case "${service}" in chatwoot_rails|chatwoot_rails_2) continue ;; esac
    recreate "${ROLLBACK_TAG}" "${service}" "${OLD_SHA}" || rollback_failed=true
  done
  recreate "${ROLLBACK_TAG}" chatwoot_rails_2 "${OLD_SHA}" || rollback_failed=true
  recreate "${ROLLBACK_TAG}" chatwoot_rails "${OLD_SHA}" || rollback_failed=true
  for service in "${APP_SERVICES[@]}"; do
    cid="$(CHATWOOT_IMAGE="${ROLLBACK_TAG}" SOURCE_SHA="${OLD_SHA}" "${COMPOSE[@]}" ps -q "${service}")"
    running_sha=""
    if [[ -n "${cid}" ]]; then
      running_sha="$(docker exec "${cid}" cat /app/.git_sha 2>/dev/null | tr -d '\r\n' || true)"
    fi
    if [[ "${running_sha}" != "${OLD_SHA}" ]]; then
      echo "rollback mismatch: ${service} runs ${running_sha:-unknown}, expected ${OLD_SHA}" >&2
      rollback_failed=true
    fi
  done
  [[ "${rollback_failed}" == false ]] || echo "rollback verification failed; operator intervention required" >&2
  exit 1
}

log "running expand-compatible database preparation with the target image"
if ! with_image run --rm --no-deps chatwoot_rails bundle exec rails db:chatwoot_prepare; then
  echo "database preparation failed before rollout; running services were not changed" >&2
  exit 1
fi

log "recreating workers before rolling web cutover"
for service in "${APP_SERVICES[@]}"; do
  case "${service}" in chatwoot_rails|chatwoot_rails_2) continue ;; esac
  recreate "${IMAGE_REF}" "${service}" || rollback "${service} did not become ready"
done
recreate "${IMAGE_REF}" chatwoot_rails_2 || rollback "chatwoot_rails_2 did not become healthy"
recreate "${IMAGE_REF}" chatwoot_rails || rollback "chatwoot_rails did not become healthy"

for service in "${APP_SERVICES[@]}"; do
  if ! cid="$(with_image ps -q "${service}")" || [[ -z "${cid}" ]]; then
    rollback "${service} has no running container"
  fi
  if ! running_sha="$(docker exec "${cid}" cat /app/.git_sha 2>/dev/null | tr -d '\r\n')"; then
    rollback "${service} revision cannot be read"
  fi
  [[ "${running_sha}" == "${SHA}" ]] || rollback "${service} runs ${running_sha:-unknown}"
done

log "running idempotent post-deploy finalizers after all runtimes match"
with_image exec -T chatwoot_rails \
  bundle exec rails runner script/onelink/finalize_release.rb || rollback "post-deploy finalizers"

persist_image_ref() {
  python3 - "${ENV_FILE}" "${IMAGE_REF}" <<'PY'
from pathlib import Path
import os
import sys

path = Path(sys.argv[1])
image = sys.argv[2]
lines = path.read_text(encoding="utf-8").splitlines()
out = []
written = False
for line in lines:
    if line.startswith("CHATWOOT_IMAGE="):
        if not written:
            out.append(f"CHATWOOT_IMAGE={image}")
            written = True
    else:
        out.append(line)
if not written:
    out.append(f"CHATWOOT_IMAGE={image}")
temporary = path.with_suffix(path.suffix + ".tmp")
temporary.write_text("\n".join(out) + "\n", encoding="utf-8")
os.chmod(temporary, path.stat().st_mode & 0o777)
os.replace(temporary, path)
PY
}

persist_image_ref || rollback "persisting CHATWOOT_IMAGE"

log "production promotion complete sha=${SHA} image=${IMAGE_REF}"
