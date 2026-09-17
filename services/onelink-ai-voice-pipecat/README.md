# OneLink AI Voice Pipecat runtime

Parallel, disabled-by-default Pipecat runtime for confirmed OneLink AI voice calls.
Rails remains the control/data plane and the existing media server remains the media plane.
`human_operator` SIP traffic is rejected at the attach boundary.

## Voice providers

The validated Rails voice context selects a provider through
`ai.provider`:

- `gemini-live`: native Gemini Live speech-to-speech. Requires `GOOGLE_API_KEY`.
- `openai-live`: native GPT Live full-duplex speech-to-speech with OpenAI Responses
  delegation for OneLink tools. Requires `OPENAI_API_KEY`. `ai.model` selects the
  live frontend model and `ai.delegation_model` selects the backend model.
- `openai-realtime`: native OpenAI Realtime speech-to-speech. Requires
  `OPENAI_API_KEY`.
- `elevenlabs`: ElevenLabs Realtime STT -> OpenRouter LLM -> ElevenLabs TTS.
  Requires `ELEVENLABS_API_KEY` and `OPENROUTER_API_KEY`.
- `cartesia`: Cartesia Ink Whisper STT -> OpenRouter LLM -> Cartesia Sonic TTS.
  Requires `CARTESIA_API_KEY` and `OPENROUTER_API_KEY`.

For `elevenlabs`, `ai.model` is the OpenRouter model and `ai.voice` is the
ElevenLabs voice ID. Optional STT/TTS model overrides are configured with
`ONELINK_AI_VOICE_PIPECAT_ELEVENLABS_STT_MODEL` and
`ONELINK_AI_VOICE_PIPECAT_ELEVENLABS_TTS_MODEL`. Provider credentials are read
only from the sidecar environment and are never accepted in attach payloads.

For `cartesia`, `ai.model` is the OpenRouter model and `ai.voice` is the
Cartesia voice ID. STT/TTS model overrides use
`ONELINK_AI_VOICE_PIPECAT_CARTESIA_STT_MODEL` and
`ONELINK_AI_VOICE_PIPECAT_CARTESIA_TTS_MODEL`.

## Active dialogue and tool progress

The session watchdog uses the validated Rails voice settings for two silence
prompts, a final silence message, optional hangup, and maximum call duration.
Every direct runtime phrase uses a provider-compatible path: Gemini realtime text
input, GPT Live commentary, an isolated OpenAI Realtime audio response with tools disabled, or a
`TTSSpeakFrame` that is not appended to the ElevenLabs/OpenRouter context.

Read-like tools continue running up to their hard `timeout_ms`. Fast results are
returned without filler audio. When a tool exceeds its per-tool or global
`foreground_wait_ms`, the runtime speaks the configured start phrase and, if the
tool is still running, the configured delay phrase. Terminal transfer/hangup
tools never emit progress filler. Mutating tools remain exactly-once fenced per
`tool_call_id` but may report progress while their single execution is pending.
The result callback is delivered exactly once after any active filler turn finishes, and a bounded
post-tool watchdog forces a continuation if the model receives the result but
does not start an answer. Silence prompts are suspended while any tool is active.

Gemini Live 3.x does not support a separate TTS frame or non-blocking tool mode.
Injecting filler through `InputTextRawFrame` would create a competing user turn,
so Gemini is instructed to announce the check before its formal function call;
the delayed-filler coordinator is used only by OpenAI Realtime and cascade mode.
