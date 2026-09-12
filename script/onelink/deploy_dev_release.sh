#!/usr/bin/env bash
set -euo pipefail

usage() {
  echo "usage: deploy_dev_release.sh [--allow-rollback] <40-char-git-sha>" >&2
  exit 64
}

[[ ${EUID} -eq 0 ]] || { echo "must run as root" >&2; exit 77; }

ALLOW_ROLLBACK=0
if [[ $# -eq 2 && "$1" == --allow-rollback ]]; then
  ALLOW_ROLLBACK=1
  shift
fi
[[ $# -eq 1 ]] || usage
SHA="$1"
[[ "${SHA}" =~ ^[0-9a-f]{40}$ ]] || usage

ROOT=/srv/onelink-dev
SOURCE_REPO="${ROOT}/onelink/chatwoot"
RELEASES="${ROOT}/releases"
CURRENT="${ROOT}/current"
ENV_FILE="${ROOT}/.env.development"
LOCK_FILE="${ROOT}/runtime/deploy.lock"
SERVICE=onelink-chatwoot-dev.service
RELEASE="${RELEASES}/onelink-dev-${SHA:0:12}"
GATE_SCRIPT=/usr/local/sbin/onelink-dev-release-gate
readonly RBENV_ROOT=/opt/rbenv
readonly DEV_TOOLCHAIN_PATH="${RBENV_ROOT}/bin:${RBENV_ROOT}/shims:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"
configure_toolchain() {
  export RBENV_ROOT
  export PATH="${DEV_TOOLCHAIN_PATH}"
  hash -r
}
configure_toolchain
PREVIOUS="$(readlink -f "${CURRENT}" 2>/dev/null || true)"
TMP_RELEASE="${RELEASE}.tmp.$$"

log() { printf '[onelink-dev-deploy] %s\n' "$*"; }
cleanup() { rm -rf "${TMP_RELEASE}"; }
trap cleanup EXIT

mkdir -p "${RELEASES}" "$(dirname "${LOCK_FILE}")"
exec 9>"${LOCK_FILE}"
flock -n 9 || { echo "another DEV deployment is active" >&2; exit 75; }

[[ -d "${SOURCE_REPO}/.git" ]] || { echo "missing deployment repository: ${SOURCE_REPO}" >&2; exit 66; }
[[ -f "${ENV_FILE}" ]] || { echo "missing DEV environment file" >&2; exit 66; }
[[ -x "${GATE_SCRIPT}" ]] || { echo "missing DEV release gate: ${GATE_SCRIPT}" >&2; exit 66; }
[[ -x "${RBENV_ROOT}/bin/rbenv" && -x "${RBENV_ROOT}/shims/bundle" ]] || {
  echo "missing DEV Ruby toolchain under ${RBENV_ROOT}" >&2
  exit 69
}
command -v pnpm >/dev/null || { echo "missing DEV pnpm executable" >&2; exit 69; }

log "fetching canonical onelink-dev branch"
git -C "${SOURCE_REPO}" fetch --quiet origin \
  +refs/heads/onelink-dev:refs/remotes/origin/onelink-dev
REMOTE_SHA="$(git -C "${SOURCE_REPO}" rev-parse refs/remotes/origin/onelink-dev)"
if ((ALLOW_ROLLBACK == 0)) && [[ "${SHA}" != "${REMOTE_SHA}" ]]; then
  echo "refusing stale/non-canonical SHA: requested=${SHA} origin/onelink-dev=${REMOTE_SHA}" >&2
  exit 65
fi
git -C "${SOURCE_REPO}" verify-commit "${SHA}" >/dev/null 2>&1 || \
  git -C "${SOURCE_REPO}" cat-file -e "${SHA}^{commit}"
if ((ALLOW_ROLLBACK == 1)) && ! git -C "${SOURCE_REPO}" branch -r --contains "${SHA}" | grep -q '[^[:space:]]'; then
  echo "refusing rollback to a commit that is not reachable from an origin branch: ${SHA}" >&2
  exit 65
fi

gate_args=(--repo "${SOURCE_REPO}" --current "${CURRENT}" --candidate "${SHA}")
((ALLOW_ROLLBACK == 1)) && gate_args+=(--allow-rollback)
log "validating candidate against the actual live release"
python3 "${GATE_SCRIPT}" "${gate_args[@]}"

if [[ ! -d "${RELEASE}" ]]; then
  log "creating immutable source release ${RELEASE}"
  rm -rf "${TMP_RELEASE}"
  mkdir -p "${TMP_RELEASE}"
  git -C "${SOURCE_REPO}" archive "${SHA}" | tar -x -C "${TMP_RELEASE}"
  printf '%s\n' "${SHA}" > "${TMP_RELEASE}/.git_sha"
  printf '%s\n' "${SHA}" > "${TMP_RELEASE}/REVISION"
  python3 - "${SHA}" > "${TMP_RELEASE}/RELEASE.json" <<'PY'
import json
import sys
print(json.dumps({"git_sha": sys.argv[1], "source_branch": "onelink-dev"}, sort_keys=True))
PY

  rm -rf "${TMP_RELEASE}/storage"
  ln -s "${SOURCE_REPO}/storage" "${TMP_RELEASE}/storage"
  mkdir -p "${TMP_RELEASE}/log" "${TMP_RELEASE}/tmp/pids"

  log "preparing Ruby and Node dependencies before cutover"
  (
    cd "${TMP_RELEASE}"
    bundle check || bundle install --jobs 4 --retry 3
    pnpm install --frozen-lockfile --prefer-offline
  )
  mv "${TMP_RELEASE}" "${RELEASE}"
fi

load_dev_env() {
  local line key value
  while IFS= read -r line || [[ -n "${line}" ]]; do
    [[ -z "${line}" || "${line}" =~ ^[[:space:]]*# || "${line}" != *=* ]] && continue
    key="${line%%=*}"
    value="${line#*=}"
    [[ "${key}" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]] || continue
    case "${key}" in
      PATH | RBENV_ROOT | DEV_TOOLCHAIN_PATH | BASH_ENV | ENV) continue ;;
    esac
    export "${key}=${value}"
  done < "${ENV_FILE}"
  configure_toolchain
  [[ "${RAILS_ENV:-development}" != production ]]
  [[ "${NODE_ENV:-development}" != production ]]
  [[ "${POSTGRES_DATABASE:-}" == chatwoot_dev ]]
}

log "running idempotent DEV database preparation"
(
  load_dev_env
  cd "${RELEASE}"
  bundle exec rails db:chatwoot_prepare
)

CURRENT_BEFORE_CUTOVER="$(readlink -f "${CURRENT}" 2>/dev/null || true)"
[[ "${CURRENT_BEFORE_CUTOVER}" == "${PREVIOUS}" ]] || {
  echo "refusing concurrent DEV cutover: expected=${PREVIOUS:-missing} current=${CURRENT_BEFORE_CUTOVER:-missing}" >&2
  exit 75
}

log "switching current symlink and restarting the DEV application group"
rm -f "${CURRENT}.next"
ln -s "${RELEASE}" "${CURRENT}.next"
mv -Tf "${CURRENT}.next" "${CURRENT}"

rollback() {
  local reason="$1"
  local current_target
  echo "DEV verification failed: ${reason}" >&2
  current_target="$(readlink -f "${CURRENT}" 2>/dev/null || true)"
  if [[ "${current_target}" == "${RELEASE}" && -n "${PREVIOUS}" && -d "${PREVIOUS}" ]]; then
    ln -s "${PREVIOUS}" "${CURRENT}.rollback"
    mv -Tf "${CURRENT}.rollback" "${CURRENT}"
    systemctl restart "${SERVICE}"
    echo "rolled back DEV to ${PREVIOUS}" >&2
  elif [[ "${current_target}" != "${RELEASE}" ]]; then
    echo "skipped rollback because current changed concurrently to ${current_target:-missing}" >&2
  fi
  exit 1
}

systemctl restart "${SERVICE}" || rollback "systemd restart"
health_deadline=$((SECONDS + 600))
while ((SECONDS < health_deadline)); do
  remaining=$((health_deadline - SECONDS))
  curl_timeout=$((remaining < 3 ? remaining : 3))
  code="$(curl -sS -o /dev/null --max-time "${curl_timeout}" -w '%{http_code}' http://127.0.0.1:3002/api/v1/profile || true)"
  if [[ "${code}" == 401 || "${code}" == 200 ]]; then
    break
  fi
  remaining=$((health_deadline - SECONDS))
  ((remaining > 0)) || break
  sleep "$((remaining < 2 ? remaining : 2))"
done
[[ "${code:-}" == 401 || "${code:-}" == 200 ]] || rollback "Rails health check HTTP ${code:-000}"

for unit in onelink-chatwoot-dev-workers.service \
  onelink-chatwoot-dev-communication-thread-realtime-worker.service; do
  [[ "$(systemctl is-active "${unit}")" == active ]] || rollback "${unit} is not active"
done

for asset in /vite-dev/@vite/client /vite-dev/entrypoints/dashboard.js; do
  code="$(curl -sS -o /dev/null --max-time 10 -w '%{http_code}' "https://dev.one-link.kz${asset}" || true)"
  [[ "${code}" == 200 ]] || rollback "asset ${asset} returned HTTP ${code:-000}"
done

RUNNING_SHA="$(cat "${CURRENT}/.git_sha")"
[[ "${RUNNING_SHA}" == "${SHA}" ]] || rollback "runtime SHA mismatch"
log "running idempotent post-deploy finalizers"
(
  load_dev_env
  cd "${CURRENT}"
  bundle exec rails runner script/onelink/finalize_release.rb
) || rollback "post-deploy finalizers"
log "DEV deployment complete sha=${SHA}"
