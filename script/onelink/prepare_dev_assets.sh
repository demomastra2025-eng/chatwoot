#!/usr/bin/env bash
set -euo pipefail

# Invoke through /root/work/e-heavy.sh BEFORE deploy_dev_release.sh is running.
[[ ${EUID} -eq 0 ]] || { echo 'must run as root' >&2; exit 77; }
[[ $# -eq 1 && "$1" =~ ^[0-9a-f]{40}$ ]] || { echo 'usage: prepare_dev_assets.sh <full-sha>' >&2; exit 64; }
readonly SHA="$1"
readonly ROOT=/srv/onelink-dev
readonly SOURCE_REPO="${ROOT}/onelink/chatwoot"
readonly ENV_FILE="${ROOT}/.env.development"
readonly ARTIFACTS="${ROOT}/runtime/built-assets"
readonly ARTIFACT="${ARTIFACTS}/${SHA}"
readonly ASSET_TOOL=/usr/local/sbin/onelink-dev-built-assets
readonly TREE_VERIFIER=/usr/local/sbin/onelink-verify-release-tree
readonly RBENV_ROOT=/opt/rbenv
readonly DEV_TOOLCHAIN_PATH="${RBENV_ROOT}/bin:${RBENV_ROOT}/shims:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"
export RBENV_ROOT PATH="${DEV_TOOLCHAIN_PATH}"

# Parse the DEV file as data, with the same strict contract as deployment.
while IFS= read -r line || [[ -n "${line}" ]]; do
  [[ -z "${line}" || "${line}" =~ ^[[:space:]]*# || "${line}" != *=* ]] && continue
  key="${line%%=*}" value="${line#*=}"
  [[ "${key}" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]] || continue
  case "${key}" in PATH | RBENV_ROOT | DEV_TOOLCHAIN_PATH | BASH_ENV | ENV) continue ;; esac
  export "${key}=${value}"
done < "${ENV_FILE}"
export PATH="${DEV_TOOLCHAIN_PATH}"
[[ "${RAILS_ENV:-development}" == development && "${NODE_ENV:-development}" != production && "${POSTGRES_DATABASE:-}" == chatwoot_dev ]] || {
  echo 'refusing non-DEV environment' >&2; exit 65;
}
case "${ONELINK_DEV_BUILT_ASSETS:-0}" in 0 | 1) ;; *) echo 'invalid ONELINK_DEV_BUILT_ASSETS value' >&2; exit 65 ;; esac
ENABLED=0
[[ -f "${ROOT}/runtime/built-assets.enabled" ]] && ENABLED=1
[[ "${ONELINK_DEV_BUILT_ASSETS:-0}" == "${ENABLED}" ]] || { echo 'DEV built-assets settings must match' >&2; exit 65; }
if ((ENABLED == 0)); then
  echo '[onelink-dev-assets] built mode disabled; no build required'
  exit 0
fi

mkdir -p "${ARTIFACTS}"
exec 8>"${ROOT}/runtime/assets.lock"
flock -n 8 || { echo 'another DEV asset preparation is active' >&2; exit 75; }
# Hold the ordinary deploy lock too, so cutover cannot start during preparation.
exec 7>"${ROOT}/runtime/deploy.lock"
flock -n 7 || { echo 'DEV deployment is active' >&2; exit 75; }
git -C "${SOURCE_REPO}" fetch --quiet origin +refs/heads/onelink-dev:refs/remotes/origin/onelink-dev
git -C "${SOURCE_REPO}" cat-file -e "${SHA}^{commit}"
git -C "${SOURCE_REPO}" merge-base --is-ancestor "${SHA}" refs/remotes/origin/onelink-dev || {
  echo 'asset SHA is not reachable from origin/onelink-dev' >&2; exit 65;
}
if [[ -d "${ARTIFACT}" ]]; then
  "${ASSET_TOOL}" verify "${ARTIFACT}" "${SHA}"
  echo "[onelink-dev-assets] reusing sealed assets sha=${SHA}"
  exit 0
fi

BUILD_DIR="$(mktemp -d "${ARTIFACTS}/.build-${SHA}.XXXXXX")"
cleanup() { rm -rf "${BUILD_DIR}"; }
trap cleanup EXIT
git -C "${SOURCE_REPO}" archive "${SHA}" | tar -x -C "${BUILD_DIR}"
"${ASSET_TOOL}" compatible "${BUILD_DIR}" "${SHA}"
(
  cd "${BUILD_DIR}"
  bundle check || bundle install --jobs 4 --retry 3
  pnpm install --frozen-lockfile --prefer-offline
  # Pin the same public path as Rails; hybrid ENV settings cannot change it.
  export RAILS_ENV=development VITE_RUBY_MODE=production VITE_RUBY_PUBLIC_OUTPUT_DIR=vite
  export VITE_RUBY_ROOT="${BUILD_DIR}" VITE_RUBY_PUBLIC_DIR=public VITE_RUBY_SOURCE_CODE_DIR=app/javascript
  export VITE_RUBY_AUTO_BUILD=false VITE_RUBY_SKIP_PROXY=true VITE_RUBY_ASSET_HOST='' VITE_RUBY_BASE=/
  export NODE_OPTIONS='--max-old-space-size=4096 --openssl-legacy-provider'
  env NODE_ENV=production BUILD_MODE='' bin/vite build --mode production --force
  env NODE_ENV=production BUILD_MODE=library bin/vite build --mode production --force
)
"${TREE_VERIFIER}" --repo "${SOURCE_REPO}" --release "${BUILD_DIR}" --sha "${SHA}"
"${ASSET_TOOL}" seal "${BUILD_DIR}" "${SHA}"
SEALED="${BUILD_DIR}/sealed"
mkdir -p "${SEALED}/public/packs/js"
mv "${BUILD_DIR}/public/vite" "${SEALED}/public/vite"
mv "${BUILD_DIR}/public/packs/js/sdk.js" "${SEALED}/public/packs/js/sdk.js"
mv "${BUILD_DIR}/DEV_BUILT_ASSETS.json" "${SEALED}/DEV_BUILT_ASSETS.json"
"${ASSET_TOOL}" verify "${SEALED}" "${SHA}"
chmod -R a-w "${SEALED}"
mv "${SEALED}" "${ARTIFACT}"
echo "[onelink-dev-assets] prepared sealed app and SDK assets sha=${SHA}"
