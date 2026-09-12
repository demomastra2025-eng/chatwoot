#!/usr/bin/env bash
set -euo pipefail

usage() {
  echo "usage: install_deploy_endpoint.sh <dev|production> <ci-public-key-file>" >&2
  exit 64
}

[[ $# -eq 2 ]] || usage
[[ ${EUID} -eq 0 ]] || { echo "must run as root" >&2; exit 77; }

ENVIRONMENT="$1"
PUBLIC_KEY_FILE="$2"
[[ -f "${PUBLIC_KEY_FILE}" ]] || usage
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

case "${ENVIRONMENT}" in
  dev)
    USER_NAME=onelink-dev-deploy
    FORCED_SOURCE="${SCRIPT_DIR}/dev_forced_command.sh"
    FORCED_TARGET=/usr/local/sbin/onelink-dev-deploy-command
    ACTION_SOURCE="${SCRIPT_DIR}/deploy_dev_release.sh"
    ACTION_TARGET=/usr/local/sbin/onelink-dev-deploy-release
    GATE_SOURCE="${SCRIPT_DIR}/dev_release_gate.py"
    GATE_TARGET=/usr/local/sbin/onelink-dev-release-gate
    ORIGINAL_VERB=deploy
    ;;
  production)
    USER_NAME=onelink-prod-deploy
    FORCED_SOURCE="${SCRIPT_DIR}/prod_forced_command.sh"
    FORCED_TARGET=/usr/local/sbin/onelink-prod-deploy-command
    ACTION_SOURCE="${SCRIPT_DIR}/promote_production.sh"
    ACTION_TARGET=/usr/local/sbin/onelink-promote-production
    ORIGINAL_VERB=promote
    ;;
  *) usage ;;
esac

for file in "${FORCED_SOURCE}" "${ACTION_SOURCE}"; do
  [[ -f "${file}" ]] || { echo "missing installer input: ${file}" >&2; exit 66; }
done

if ! id "${USER_NAME}" >/dev/null 2>&1; then
  useradd --create-home --home-dir "/var/lib/${USER_NAME}" --shell /bin/bash "${USER_NAME}"
fi
install -o root -g root -m 0755 "${FORCED_SOURCE}" "${FORCED_TARGET}"
install -o root -g root -m 0755 "${ACTION_SOURCE}" "${ACTION_TARGET}"
if [[ "${ENVIRONMENT}" == dev ]]; then
  [[ -f "${GATE_SOURCE}" ]] || { echo "missing installer input: ${GATE_SOURCE}" >&2; exit 66; }
  install -o root -g root -m 0755 "${GATE_SOURCE}" "${GATE_TARGET}"
fi

HOME_DIR="$(getent passwd "${USER_NAME}" | cut -d: -f6)"
install -d -o "${USER_NAME}" -g "${USER_NAME}" -m 0700 "${HOME_DIR}/.ssh"
PUBLIC_KEY="$(sed -n '1p' "${PUBLIC_KEY_FILE}")"
KEY_TYPE="${PUBLIC_KEY%% *}"
if [[ "${KEY_TYPE}" != ssh-ed25519 ]] || ! ssh-keygen -l -f "${PUBLIC_KEY_FILE}" >/dev/null; then
  echo "only Ed25519 CI keys are accepted" >&2
  exit 65
fi
printf 'restrict,command="%s" %s\n' "${FORCED_TARGET}" "${PUBLIC_KEY}" > "${HOME_DIR}/.ssh/authorized_keys"
chown "${USER_NAME}:${USER_NAME}" "${HOME_DIR}/.ssh/authorized_keys"
chmod 0600 "${HOME_DIR}/.ssh/authorized_keys"

SUDOERS="/etc/sudoers.d/${USER_NAME}"
printf '%s ALL=(root) NOPASSWD: %s *\n' "${USER_NAME}" "${ACTION_TARGET}" > "${SUDOERS}"
chmod 0440 "${SUDOERS}"
visudo -cf "${SUDOERS}" >/dev/null

printf 'installed %s endpoint for verb %s\n' "${ENVIRONMENT}" "${ORIGINAL_VERB}"
