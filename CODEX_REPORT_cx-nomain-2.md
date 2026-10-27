# cx-nomain-2: removal of «Главный агент»

Base: `3d77ef5701548999166e28c73753f10a27806bf8`. Work continued on the checked-out `codex/cx-nomain-2` branch from the interrupted WIP commit. No remote, deployment, or production system was used.

## What changed

- Completed the WIP removal of the workspace main agent. Text channels now use a channel scope; enabled agents are peers selected by the router. Every agent has the same whole-agent on/off switch. With two or more enabled agents and no descriptions, automatic replies stop and staff receive a localized notice telling them to fill in the agent descriptions. Turning off the final agent leaves AI silent. Workspaces without external agents retain the simple reply suggestion path.
- Kept one assigned voice agent for each phone number, including WhatsApp numbers with AI voice enabled. Voice calls do not use the text router.
- Kept conversation ownership, prior replies, scenario display names, and the existing technical handoff behavior while moving response jobs to channel scope. Adjusted the older response-job fixtures to model a conversation already held by an agent; new conversations start without a holder.
- Made benchmark accounts and voice spec accounts capable of creating their intended channels. Tightened the matrix store spec to assert the complete top-level response shape and removed an empty spec group.
- The WIP already changed backend consumers, the frontend, and Russian, Kazakh, and English translations. The final grep gate below found no main-agent references outside voice routing.

## Migration and retained data

Migration `20261027150000_remove_main_agent.rb` copies the former account default and text inbox assignments to `captain_main_agent_backups` before clearing them. Its `down` restores surviving assignments and gives a newly created text row a valid enabled fallback agent; if none exists, it removes that unusable row as specified in the plan. The backup table is removed only on rollback. I ran `db:rollback STEP=1`, `db:migrate`, `db:rollback STEP=1`, then `db:migrate` on the isolated `chatwoot_codex_nomain_features` test database; all commands succeeded. The migration spec passed in the initial targeted suite.

The `captain_assistants.channel_scope` column remains in `ignored_columns`. The `captain_agent_channels` and `captain_agent_handoffs` tables remain. No other migration or data deletion was added.

## Verification

Test databases were created with `source ~/.test-env`, isolated `POSTGRES_DATABASE` names, and `bundle exec rails db:create db:schema:load`. Ruby specs used `bundle exec rspec -r /home/codex-e/vite_stub.rb`. The base worktree is `../base-nomain`, checked out at the base SHA with its own databases. The local test secret was copied into each worktree without displaying it.

| Check | Head result | Base comparison or explanation |
| --- | --- | --- |
| Core routing/migration group, first run | 133 examples, 2 run-fence fixture failures | Both fixture cases were corrected; focused rerun: 30 examples, 0 failures. |
| Core routing, migration, suggestion, and council final suite | 233 examples, 0 failures | Includes the full migration spec and both council suites. |
| Response builder, ownership, fence, hook group, first run | 268 examples, 39 failures from old anchor-based fixtures | Updated fixtures and preserved scenario display names. |
| Response group, intermediate rerun | 221 examples, 7 failures | Six focused reruns after fixes: 6 examples, 0 failures. The remaining greeting failure also occurred on base. |
| Response builder, ownership, fence, and hook final suite | 228 examples, 0 failures | The base response builder and hook suite had the one greeting failure recorded below. |
| Response builder and hook base suite | — | 202 examples, 1 greeting failure. |
| Feature suite against a migrated head database | 552 examples, 41 failures | That database had acquired the historical default scheduling feature while the schema-loaded base database had not. Its tool and channel fixtures were therefore not comparable; 42 focused voice/benchmark examples passed after fixture correction. |
| Isolated default-tool example on the migrated head database | 1 example, 1 failure on each of two runs because scheduling added a catalog tool | The same example on the schema-loaded base database passed (1 example). Rails runner confirmed scheduling was enabled by default only in the migrated database. |
| Feature suite on a clean, schema-loaded head database | 552 examples, 0 failures | Base corresponding files: 508 examples, 0 failures. New head-only files do not exist at base. |
| All 14 changed frontend spec files | 128 tests, 0 failures | Base corresponding 7 files: 97 tests, 0 failures. |
| Matrix store spec after final edit | 8 tests, 0 failures | ESLint `--quiet` and Prettier also pass for this file. |
| Translation key guard | 3 failures, missing-key counts ru 235, en 241, kk 108 | The base has the same 3 failures and identical counts. |
| Ruby syntax for changed Ruby files; `git diff --check` | Pass | No syntax or whitespace errors. |
| Changed JavaScript ESLint | One error: unused `portalSlug` in `ReplyBottomPanel.vue:165` | The same error exists at base. |
| RuboCop on touched Ruby files | Pre-existing complexity, length, and RSpec style offenses; commit hook passed with `--fail-level E` | No new offense in the added lines. |
| Changed locale JSON Prettier | Pass | — |

Two broad-suite commands initially used incorrect spec paths and exited with 0 examples and load errors; their corrected commands are the clean feature and final response suite entries. `pnpm install --frozen-lockfile` succeeded before the frontend checks because `node_modules` was absent.

## Grep gate

The plan's backend grep pattern over `app enterprise lib` returned only these voice-specific references:

```text
app/services/telephony/ai_voice/tool_dispatch_service.rb:1141
app/services/telephony/ai_voice/context_builder.rb:608
app/services/telephony/ai_voice/post_call_captain_features_service.rb:162
app/services/telephony/ai_voice/conversation_timeline_service.rb:334
app/controllers/api/v1/accounts/inboxes_controller.rb:348
enterprise/app/services/captain/tools/account/get_inbox_settings_service.rb:78-79
enterprise/app/services/captain/tools/account/update_captain_inbox_auto_reply_mode_service.rb:60
enterprise/app/services/captain/tools/account/list_inboxes_service.rb:130-131
```

The plan's `app/javascript` grep pattern returned no matches. `rg 'Touch|Касание' app/javascript/dashboard/i18n/locale config/locales` also returned no matches.

## Open points

- The `docs/` submodule is unpopulated in this local clone (`git submodule status` shows `-304d811…`), so the required documentation alignment could not be committed here without fetching another repository. The release pipeline should provide that submodule for a docs update.
- The repository-wide translation key guard and the existing `ReplyBottomPanel.vue` lint error remain baseline failures. They are unrelated to this removal.
