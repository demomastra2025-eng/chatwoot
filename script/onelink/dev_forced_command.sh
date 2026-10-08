#!/usr/bin/env bash
set -euo pipefail

readonly DEPLOY_SCRIPT=/usr/local/sbin/onelink-dev-deploy-release
readonly VERIFY_SCRIPT=/usr/local/sbin/onelink-dev-verify-release
readonly ASSET_PREPARER=/usr/local/sbin/onelink-dev-prepare-assets
readonly ASSET_TOOL=/usr/local/sbin/onelink-dev-built-assets
readonly COMMAND="${SSH_ORIGINAL_COMMAND:-}"

if [[ "${COMMAND}" == deploy-script-sha256 ]]; then
  sha256sum "${DEPLOY_SCRIPT}" | cut -d' ' -f1
  exit 0
fi

if [[ "${COMMAND}" == asset-tools-sha256 ]]; then
  sha256sum "${ASSET_PREPARER}" "${ASSET_TOOL}" | cut -d' ' -f1
  exit 0
fi

if [[ "${COMMAND}" =~ ^prepare-assets[[:space:]]([0-9a-f]{40})$ ]]; then
  # e-heavy refuses any active deploy process: preparation must be a separate verb.
  exec sudo --non-interactive /root/work/e-heavy.sh "${ASSET_PREPARER}" "${BASH_REMATCH[1]}"
fi

if [[ "${COMMAND}" =~ ^deploy[[:space:]]([0-9a-f]{40})$ ]]; then
  exec sudo --non-interactive "${DEPLOY_SCRIPT}" "${BASH_REMATCH[1]}"
fi

if [[ "${COMMAND}" =~ ^rollback[[:space:]]([0-9a-f]{40})$ ]]; then
  exec sudo --non-interactive "${DEPLOY_SCRIPT}" --allow-rollback "${BASH_REMATCH[1]}"
fi

if [[ "${COMMAND}" =~ ^verify[[:space:]]([0-9a-f]{40})$ ]]; then
  exec sudo --non-interactive "${VERIFY_SCRIPT}" "${BASH_REMATCH[1]}"
fi

echo "Only endpoint hashes, 'prepare-assets <full-sha>', 'deploy <full-sha>', 'rollback <full-sha>', or 'verify <full-sha>' are allowed." >&2
exit 64
