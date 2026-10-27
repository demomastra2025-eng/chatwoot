# cx-stream-r review report

Base: `3d77ef5701548999166e28c73753f10a27806bf8`

Reviewed implementation: `df36bd690`, `7207517f3`
Review fixes: `83dc47c23`, `a61d4c181`

## Result and design

The reply-suggestion agent streams RubyLLM/OpenRouter answer chunks through `Llm::Runtime` and `Captain::Runtime::AnswerStream`. `Captain::ReplySuggestion::DraftStream` reads only the structured `response` field and sends throttled previews over the requesting staff user's existing ActionCable token. The dashboard accepts previews only for its tracked request and conversation, renders them in the suggestion panel, and replaces them with the normal final result. Previews are not messages and are not written to the progress snapshot. The customer channel is never used.

The provider schema now asks for `response_mode` before `response` (`enterprise/lib/captain/suggestion_response_schema.rb:15-17`). The stream requires an explicit `reply` mode before publishing any text (`enterprise/app/services/captain/reply_suggestion/draft_stream.rb:116-123`). If a provider emits `response` first, the text is buffered until the mode arrives. For `human` or `suppress`, even a nonempty `response` stays hidden. This choice keeps early text when the provider follows schema order without trusting order as a safety condition.

**Time to first text:** no live provider timing was possible. The estimated extra delay after the first generated token is roughly 0.4–1.0 seconds at an assumed 40–80 tokens/second, for the JSON prefix, explicit mode, and first 12 response characters; provider first-token latency and tool execution add to that. A provider that emits the mode last shows no early text. The provider test uses scripted SSE chunks and confirms that streaming returns the same final response as a non-streamed call; it is not a latency benchmark.

## Findings fixed

1. The original preview published `response` before the later `response_mode` was known. A nonempty `human` or `suppress` response could briefly reach staff. Reordered the schema, gated publication on `reply`, and added mode-first and mode-last cases (`draft_stream.rb:116-123`, `spec/enterprise/services/captain/reply_suggestion/draft_stream_spec.rb`).
2. Repeated JSON keys could replace an already previewed mode or response in the final parser. The reader now stops previewing on repeated tracked keys and clears an existing preview (`enterprise/app/services/captain/reply_suggestion/draft_stream/field_reader.rb:110-136`). The incremental string decoder was separated into `field_reader/string_decoder.rb` so the parser and its lint checks stay manageable.
3. `finish!` could broadcast immediately after a preview and exceed the 200 ms interval. It now observes the same interval; the normal result event supplies the complete final draft (`draft_stream.rb:50-58`). A clear event remains immediate so withdrawn text disappears promptly.
4. The dashboard accepted preview events with no conversation id or no valid sequence. It now requires the tracked conversation and an increasing safe integer sequence (`app/javascript/dashboard/composables/useCopilotReply.js:760-771`).

## Kept and rejected

- Kept the existing provider stream path, final response normalization, safety checks, outcome classification, user-token broadcaster, compact AI panel, mobile scroll behavior, and ru/kk/en `WRITING` key. The scripted provider test covers tool calls followed by a structured answer and equal final output.
- Kept the 12-character first-preview threshold and 20,000-character parser bound. They avoid a one-letter flash and bound partial-text work; the full final result remains unaffected.
- Rejected showing text before an explicit mode, even when a prompt tells the model to leave non-draft responses empty. A prompt cannot guarantee that behavior.
- Rejected a new finalization call to force tool-free streaming because it would regenerate the answer and could change the final draft, contrary to this task.
- No migrations, data deletion, new persistence path, new customer broadcast, or secrets were added.

## Verification

Commands were run in this local clone and the detached base worktree, with separate `chatwoot_codex_stream` and `chatwoot_codex_stream_base` databases. `source /home/codex-e/.test-env` preceded database and RSpec commands; no environment values were printed. No production access was used.

| Check | Head | Base |
| --- | --- | --- |
| `bundle exec rails db:create db:schema:load` | Passed; database created | Passed; database created |
| `bundle exec rspec -r /home/codex-e/vite_stub.rb` on all changed Ruby specs plus runner, classifier, dialog and suggestion service suites | 251 examples, 0 failures | 182 examples, 0 failures on the suites present at base |
| Focused `draft_stream_spec.rb` after the last test edit | 19 examples, 0 failures | Not present at base |
| `pnpm exec vitest run` on `CopilotEditorSection.spec.js`, `useCopilotReply.spec.js`, `actionCable.spec.js`, `translationKeys.spec.js` | 238 passed, 3 failed, 241 total | 213 passed, 3 failed, 216 total |
| `pnpm exec eslint` on the changed JS/Vue surface | Passed with 35 i18n-resource warnings; focused final run passed with 2 such warnings | Not run |
| `bundle exec rubocop` on changed Ruby/spec files | Final: 7 files, no offenses | Not run |
| `pnpm exec prettier --check` on changed JS/Vue and ru/kk/en JSON | Passed | Not run |
| `ruby -c` on changed Ruby implementation files; `git diff --check` | Passed | Not run |
| `pnpm install --frozen-lockfile` | Passed; installed missing `node_modules` | Base Vitest used a symlink to the same installed dependencies |

The three `translationKeys.spec.js` failures are identical on head and base: missing keys in pre-existing dashboard surfaces (235 ru, 241 en, 108 kk). The new `WRITING` key is present in all three locales and is absent from the missing-key list. The first head RSpec pass, run while review edits were in progress, had 250 examples and 2 failures in collector fixtures that still used the old schema order; the final run above passed. The initial RuboCop pass found 12 offenses in the new parser/spec; the final pass passed. No functionality tests were weakened or deleted.

## Open questions and limits

- The test proves RubyLLM can consume scripted structured SSE chunks and preserve the final answer. A live OpenRouter/provider run, actual first-text timing, and provider-specific field order were not verified here. If a provider emits mode last, the safe behavior is to wait.
- The runtime streams model turns that may call tools, while tool-call chunks in the scripted integration test have no structured reply text. If a provider emits a draft-shaped `response` and then a tool call in the same turn, a preview could appear briefly before the existing tool-start reset clears it. Guaranteeing that no such transient text ever appears would require knowing the future tool decision or changing the generation flow; this needs a product/runtime decision if observed in live traffic.
- A later safety rule or outcome classifier can still reject a model `reply` after staff saw a preview. The final result replaces or clears the preview; preview text is never sent to the customer. Avoiding all such transient previews would require waiting for the final checks and would remove early text.
- `docs/` is an uninitialized git submodule in this offline clone (`git submodule status docs` reports a leading `-`). Documentation content could not be updated or committed without its repository; no remote was added.
