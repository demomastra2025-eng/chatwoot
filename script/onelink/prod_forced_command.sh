#!/usr/bin/env bash
set -euo pipefail

readonly PROMOTE_SCRIPT=/usr/local/sbin/onelink-promote-production
readonly COMMAND="${SSH_ORIGINAL_COMMAND:-}"

if [[ "${COMMAND}" =~ ^promote[[:space:]]([0-9a-f]{40})[[:space:]](ghcr\.io/demomastra2025-eng/chatwoot@sha256:[0-9a-f]{64})$ ]]; then
  exec sudo --non-interactive "${PROMOTE_SCRIPT}" "${BASH_REMATCH[1]}" "${BASH_REMATCH[2]}"
fi

echo "Only 'promote <full-sha> <immutable-ghcr-digest>' is allowed." >&2
exit 64
