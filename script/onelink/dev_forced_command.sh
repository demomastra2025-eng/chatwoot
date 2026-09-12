#!/usr/bin/env bash
set -euo pipefail

readonly DEPLOY_SCRIPT=/usr/local/sbin/onelink-dev-deploy-release
readonly VERIFY_SCRIPT=/usr/local/sbin/onelink-dev-verify-release
readonly COMMAND="${SSH_ORIGINAL_COMMAND:-}"

if [[ "${COMMAND}" =~ ^deploy[[:space:]]([0-9a-f]{40})$ ]]; then
  exec sudo --non-interactive "${DEPLOY_SCRIPT}" "${BASH_REMATCH[1]}"
fi

if [[ "${COMMAND}" =~ ^rollback[[:space:]]([0-9a-f]{40})$ ]]; then
  exec sudo --non-interactive "${DEPLOY_SCRIPT}" --allow-rollback "${BASH_REMATCH[1]}"
fi

if [[ "${COMMAND}" =~ ^verify[[:space:]]([0-9a-f]{40})$ ]]; then
  exec sudo --non-interactive "${VERIFY_SCRIPT}" "${BASH_REMATCH[1]}"
fi

echo "Only 'deploy <full-sha>', 'rollback <full-sha>', or 'verify <full-sha>' is allowed." >&2
exit 64
