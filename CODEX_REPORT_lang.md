# Task lang report

## Changes

- Added the installation-wide `CAPTAIN_LANGUAGE_DETECTION_MODEL` setting, defaulting to `openai/gpt-6-luna-decisions`, and allowed that model through the existing OpenRouter Decisions transport. The decision uses the agent's OpenRouter key.
- Added `Captain::PatientLanguageDetector`. Before an agent run, it sends one decision request containing the last 20 public incoming patient messages, oldest first and numbered. It includes available voice transcriptions and skips messages without text. A two-second timeout or error gives no hint and logs only the error class. The result is reused through the run, including retries and council work.
- Stored the last decided `ru`, `kk`, or `en` code in conversation `additional_attributes`. `unknown` reuses it; `other` clears it. The prompt names the result in the `# Now` block, for example: `Patient language: Kazakh. Reply in Kazakh.` Council parts and the editor receive the same hint. The platform rule is now `Reply in the patient's language.`
- AI-written handoff and closing notices use the saved hint. When the notice model fails, the built-in fallback can now handle English too. Removed the former text-based notice language heuristic.
- Updated the routing benchmark README to account for the extra Decisions request. The benchmark still uses the OpenRouter-only HTTP path and the agent's key.

## Kept and decisions

- Kept the `patient_language` response and part fields because council assembly, logging, and the routing benchmark still read them. They are metadata; the decision hint controls the requested reply language.
- Kept fixed notice text and the existing notice mode configuration. With no decided language, a generated notice gets no language hint; its built-in fallback uses the workspace locale.
- No migration or account-level switch was added. The selected code is stored in the existing conversation attributes.

## Verification

| Check | Result |
| --- | --- |
| `pnpm install --frozen-lockfile` | Passed; dependencies installed. |
| `pnpm vitest run app/javascript/dashboard/i18n/specs/translationKeys.spec.js` | Passed, 5 tests. |
| `pnpm exec eslint app/javascript/dashboard/i18n/specs/translationKeys.spec.js` | Passed. |
| `ruby -c` on all 31 changed Ruby files | Passed. |
| `ruby -ryaml` safe-load of `config/llm.yml` and `config/installation_config.yml` | Passed. |
| `bundle exec rubocop enterprise/app/services/captain/patient_language_detector.rb spec/enterprise/services/captain/patient_language_detector_spec.rb --format simple` | Passed, no offenses. |
| `bundle exec rubocop --format json` on all 31 changed Ruby files | Failed with 168 offenses in the touched files; an audit of added and changed lines found zero offenses there. The commit hooks also reported existing offenses and applied formatting. |
| `git diff HEAD~3 HEAD --check` | Passed. |
| Backend RSpec and the routing benchmark | Not run: this machine has no PostgreSQL or Redis. No backend test result is claimed. |

RSpec files for the release orchestrator:

```text
spec/controllers/super_admin/app_config_controller_spec.rb
spec/enterprise/lib/captain/assistant_prompt_spec.rb
spec/enterprise/lib/captain/patient_language_spec.rb
spec/enterprise/lib/captain/runtime/chat_factory_spec.rb
spec/enterprise/lib/captain/runtime/council_editor_spec.rb
spec/enterprise/models/captain/assistant_spec.rb
spec/enterprise/services/captain/assistant/agent_runner_service_spec.rb
spec/enterprise/services/captain/customer_notice_service_spec.rb
spec/enterprise/services/captain/patient_language_detector_spec.rb
spec/lib/llm/config_spec.rb
spec/lib/llm/installation_model_config_spec.rb
spec/lib/llm/models_spec.rb
spec/lib/llm/open_router_capability_resolver_spec.rb
spec/lib/llm/open_router_decision_runtime_spec.rb
```

## Open questions and limitations

- The `docs/` submodule is not checked out in this clone, so client-facing and internal docs there could not be updated. The in-repo routing benchmark README was updated.
- Release infrastructure still needs to run the listed RSpec files and the routing benchmark with its isolated database and Redis.
