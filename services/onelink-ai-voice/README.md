# OneLink AI Voice Service

Realtime voice runtime for OneLink/Fonoster calls.

Ownership split:

- Fonoster: call/media execution.
- `onelink-ai-voice`: realtime audio session, Gemini Live adapter, transcript/tool/control buffering.
- Rails/Chatwoot: routing, context, Captain config, tools, transcript persistence, lifecycle/audit.

Audio must stay out of Rails: `Fonoster <-> onelink-ai-voice <-> Gemini Live`.
Rails is used only through authenticated internal control-plane APIs.

Required env:

- `ONELINK_INTERNAL_BASE_URL`
- `ONELINK_INTERNAL_TOKEN`
- `VOICE_AGENT_REALTIME_API_KEY` or `GEMINI_API_KEY`

Scripts:

- `npm test`
- `npm start`
