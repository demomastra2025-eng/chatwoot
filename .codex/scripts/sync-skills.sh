#!/usr/bin/env bash

set -euo pipefail

MODE="${1:-to-codex-home}"
PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
PROJECT_SKILLS_DIR="$PROJECT_ROOT/.codex/skills"
CODEX_HOME_DIR="${CODEX_HOME:-$HOME/.codex}"
CODEX_SKILLS_DIR="$CODEX_HOME_DIR/skills"

copy_skills() {
  local source_dir="$1"
  local target_dir="$2"
  local copied=0

  mkdir -p "$target_dir"
  shopt -s nullglob

  for skill_dir in "$source_dir"/onelink-*; do
    local skill_name
    skill_name="$(basename "$skill_dir")"
    rm -rf "$target_dir/$skill_name"
    cp -R "$skill_dir" "$target_dir/$skill_name"
    copied=$((copied + 1))
  done

  shopt -u nullglob

  if [[ "$copied" -eq 0 ]]; then
    echo "No onelink-* skills found in $source_dir" >&2
    exit 1
  fi

  echo "Synced $copied skills from $source_dir to $target_dir"
}

case "$MODE" in
  to-codex-home)
    copy_skills "$PROJECT_SKILLS_DIR" "$CODEX_SKILLS_DIR"
    ;;
  from-codex-home)
    copy_skills "$CODEX_SKILLS_DIR" "$PROJECT_SKILLS_DIR"
    ;;
  *)
    echo "Usage: $0 [to-codex-home|from-codex-home]" >&2
    exit 1
    ;;
esac
