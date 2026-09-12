#!/usr/bin/env bash
set -euo pipefail

readonly DEPLOY_SCRIPT=/usr/local/sbin/onelink-dev-deploy-release
readonly COMMAND="${SSH_ORIGINAL_COMMAND:-}"

if [[ "${COMMAND}" =~ ^deploy[[:space:]]([0-9a-f]{40})$ ]]; then
  exec sudo --non-interactive "${DEPLOY_SCRIPT}" "${BASH_REMATCH[1]}"
fi

echo "Only 'deploy <full-sha>' is allowed." >&2
exit 64
