#!/usr/bin/env bash
set -uo pipefail

usage() {
  echo "usage: verify_dev_release.sh [--contracts-only] <40-char-git-sha>" >&2
  exit 64
}

MODE=full
if [[ ${1:-} == --contracts-only ]]; then
  MODE=contracts
  shift
fi
[[ $# -eq 1 ]] || usage
SHA="$1"
[[ "${SHA}" =~ ^[0-9a-f]{40}$ ]] || usage

readonly ROOT=${ONELINK_DEV_ROOT:-/srv/onelink-dev}
readonly SOURCE_REPO="${ROOT}/onelink/chatwoot"
readonly CURRENT="${ROOT}/current"
readonly ENV_FILE="${ROOT}/.env.development"
readonly RELEASE="${ROOT}/releases/onelink-dev-${SHA:0:12}"
readonly TREE_VERIFIER=${ONELINK_TREE_VERIFIER:-/usr/local/sbin/onelink-verify-release-tree}
readonly RBENV_ROOT=/opt/rbenv
readonly TEST_SEED=4816395
readonly DEV_TOOLCHAIN_PATH="${RBENV_ROOT}/bin:${RBENV_ROOT}/shims:/opt/node-24/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"

SPEC_FILES=(
  spec/services/confirmations/resolve_service_spec.rb
  spec/services/integrations/medelement/provider_commands/create_service_spec.rb
  spec/services/integrations/medelement/provider_commands/create_service_concurrency_spec.rb
  spec/services/integrations/medelement/appointment_provider_command_receipt_service_spec.rb
  spec/services/integrations/medelement/appointment_provider_command_receipt_lookup_service_spec.rb
  spec/services/integrations/medelement/appointment_provider_status_spec.rb
  spec/services/integrations/medelement/outbound_change_service_spec.rb
  spec/services/scheduling/available_slot_search_service_spec.rb
  spec/services/scheduling/calendar_view_service_spec.rb
  spec/services/scheduling/id_list_param_parser_spec.rb
  spec/enterprise/services/captain/tools/copilot/search_available_slots_service_spec.rb
  spec/requests/api/v1/accounts/scheduling/appointments_spec.rb
)
RUBOCOP_FILES=(
  app/controllers/api/v1/accounts/scheduling/base_controller.rb
  app/controllers/api/v1/accounts/scheduling/calendar_controller.rb
  app/services/confirmations/resolve_service.rb
  app/services/integrations/medelement/appointment_provider_command_receipt_lookup_service.rb
  app/services/integrations/medelement/appointment_provider_command_receipt_service.rb
  app/services/integrations/medelement/appointment_provider_status.rb
  app/services/integrations/medelement/outbound_change_service.rb
  app/services/integrations/medelement/provider_commands/create_service.rb
  app/services/scheduling/calendar_view_service.rb
  app/services/scheduling/id_list_param_parser.rb
  config/environments/development.rb
  spec/requests/api/v1/accounts/scheduling/appointments_spec.rb
  spec/services/confirmations/resolve_service_spec.rb
  spec/services/integrations/medelement/appointment_provider_command_receipt_lookup_service_spec.rb
  spec/services/integrations/medelement/appointment_provider_command_receipt_service_spec.rb
  spec/services/integrations/medelement/appointment_provider_status_spec.rb
  spec/services/integrations/medelement/outbound_change_service_spec.rb
  spec/services/integrations/medelement/provider_commands/create_service_concurrency_spec.rb
  spec/services/integrations/medelement/provider_commands/create_service_spec.rb
  spec/services/scheduling/calendar_view_service_spec.rb
  spec/services/scheduling/id_list_param_parser_spec.rb
)
SYNTAX_FILES=(
  "${RUBOCOP_FILES[@]}"
  enterprise/lib/captain/tools/operations/appointment_operations.rb
  spec/services/scheduling/available_slot_search_service_spec.rb
  spec/enterprise/services/captain/tools/copilot/search_available_slots_service_spec.rb
)

print_command() {
  printf 'command='
  printf '%q ' "$@"
  printf '\n'
}

run_and_record() {
  local name="$1"
  shift
  print_command "$@"
  "$@"
  local status=$?
  printf '%s_exit_code=%s\n' "${name}" "${status}"
  return "${status}"
}

[[ ${EUID} -eq 0 ]] || { echo "must run as root" >&2; exit 77; }
[[ -d "${SOURCE_REPO}/.git" ]] || { echo "missing deployment repository: ${SOURCE_REPO}" >&2; exit 66; }
[[ -d "${RELEASE}" ]] || { echo "missing exact release: ${RELEASE}" >&2; exit 66; }
[[ -f "${ENV_FILE}" ]] || { echo "missing DEV environment file" >&2; exit 66; }
[[ -x "${TREE_VERIFIER}" ]] || { echo "missing release tree verifier: ${TREE_VERIFIER}" >&2; exit 66; }
[[ "$(< "${RELEASE}/.git_sha")" == "${SHA}" ]] || { echo "release SHA mismatch" >&2; exit 65; }
if [[ "${MODE}" == full ]]; then
  [[ "$(readlink -f "${CURRENT}")" == "${RELEASE}" ]] || { echo "exact SHA is not the deployed release" >&2; exit 65; }
fi

export RBENV_ROOT
export PATH="${DEV_TOOLCHAIN_PATH}"
hash -r
cd "${RELEASE}"

printf 'artifact=OneLink DEV deployed-release verification\n'
printf 'sha=%s\n' "${SHA}"
printf 'release=%s\n' "${RELEASE}"
printf 'mode=%s\n' "${MODE}"
printf 'start_utc=%s\n' "$(date -u +%FT%TZ)"
printf 'rspec_seed=%s\n' "${TEST_SEED}"
printf 'line_filters=none\n'
printf 'spec_count=%s\n' "${#SPEC_FILES[@]}"
printf 'spec_file=%s\n' "${SPEC_FILES[@]}"

status=0
rspec_command=(
  bundle exec dotenv -f "${ENV_FILE}" -- env -u DATABASE_URL
  RAILS_ENV=test NODE_ENV=test POSTGRES_DATABASE=chatwoot_test
  bundle exec rspec --seed "${TEST_SEED}" "${SPEC_FILES[@]}"
)
run_and_record rspec "${rspec_command[@]}" || status=1

if [[ "${MODE}" == full ]]; then
  run_and_record rubocop bundle exec rubocop --force-exclusion "${RUBOCOP_FILES[@]}" || status=1

  printf 'command=ruby -c <each ruby_file>\n'
  syntax_status=0
  for file in "${SYNTAX_FILES[@]}"; do
    ruby -c "${file}" || syntax_status=1
  done
  printf 'ruby_syntax_exit_code=%s\n' "${syntax_status}"
  ((syntax_status == 0)) || status=1
fi

run_and_record tree "${TREE_VERIFIER}" --repo "${SOURCE_REPO}" --release "${RELEASE}" --sha "${SHA}" || status=1
printf 'end_utc=%s\n' "$(date -u +%FT%TZ)"
printf 'verification_exit_code=%s\n' "${status}"
exit "${status}"
