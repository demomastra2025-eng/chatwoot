#!/bin/sh
set -eu

recording_root=${ONELINK_AI_VOICE_PIPECAT_RECORDING_ROOT:-/app/storage}
case "$recording_root" in
  /*) ;;
  *)
    printf 'ONELINK_AI_VOICE_PIPECAT_RECORDING_ROOT must be absolute\n' >&2
    exit 64
    ;;
esac

recording_dir=${recording_root%/}/voice-recordings
mkdir -p -- "$recording_dir"
chown onelink:onelink "$recording_dir"

exec setpriv --reuid=onelink --regid=onelink --init-groups "$@"
