const { OnelinkClient } = require('./onelink/client');
const { SessionRegistry } = require('./sessions/session-registry');
const { GeminiLiveClient } = require('./realtime/gemini-live-client');
const { VoiceApplication } = require('./app/voice-application');
const { createHealthServer } = require('./diagnostics/health-server');
const { startFonosterVoiceServer } = require('./fonoster/server');
const { createWhatsappInternalHandler } = require('./whatsapp/internal-server');
const { createWhatsappRuntimeMediaStreamFactory } = require('./whatsapp/runtime-stream');
const { loadConfig } = require('./config');

async function main() {
  const config = loadConfig();
  const client = new OnelinkClient({
    baseUrl: config.railsBaseUrl,
    token: config.internalToken,
    bridgeToken: config.bridgeToken,
    contextPath: config.contextPath,
    transcriptPath: config.transcriptPath,
    controlPath: config.controlPath,
    eventPath: config.eventPath,
    finalizePath: config.finalizePath
  });
  const registry = new SessionRegistry({ ttlMs: config.sessionTtlMs });
  const app = new VoiceApplication({
    client,
    registry,
    toolTimeoutMs: config.toolTimeoutMs,
    outputMaxBufferedMs: config.outputMaxBufferedMs,
    postToolContinuationMs: config.postToolContinuationMs,
    clearOutputOnInterrupt: config.clearAudioOnInterrupt,
    mediaStreamFactory: createWhatsappRuntimeMediaStreamFactory(),
    realtimeFactory: ({ context, onAudio, onTranscript, onToolCall, onInterrupt, onEvent }) => new GeminiLiveClient({
      apiKey: config.geminiApiKey,
      model: context.ai?.model || config.geminiModel,
      voice: context.ai?.voice || config.geminiVoice,
      language: context.ai?.language || config.language,
      temperature: context.ai?.temperature ?? config.temperature,
      maxOutputTokens: context.ai?.max_output_tokens ?? context.ai?.maxOutputTokens ?? config.maxOutputTokens,
      setupTimeoutMs: config.setupTimeoutMs,
      interruptions: context.ai?.interruptions_enabled ?? config.interruptions,
      interruptionMode: context.ai?.interruption_mode || context.ai?.interruptionMode || config.interruptionMode,
      speechStartSensitivity: context.ai?.speech_start_sensitivity || config.speechStartSensitivity,
      speechEndSensitivity: context.ai?.speech_end_sensitivity || config.speechEndSensitivity,
      prefixPaddingMs: context.ai?.prefix_padding_ms ?? context.ai?.prefixPaddingMs ?? config.prefixPaddingMs,
      silenceDurationMs: context.ai?.silence_duration_ms ?? context.ai?.silenceDurationMs ?? config.silenceDurationMs,
      turnCoverage: context.ai?.turn_coverage || context.ai?.turnCoverage || config.turnCoverage,
      onAudio,
      onTranscript,
      onToolCall,
      onInterrupt,
      onEvent
    })
  });

  const health = createHealthServer({
    registry,
    port: config.apiPort,
    handlers: [createWhatsappInternalHandler({
      app,
      internalToken: config.internalToken,
      path: config.whatsappAttachPath
    })]
  });
  await health.listen();

  const voiceServer = await startFonosterVoiceServer({
    port: config.grpcPort,
    skipIdentity: config.skipIdentity,
    identityAddress: config.identityAddress,
    app,
  });

  console.log(JSON.stringify({ event: 'voice_service_started', apiPort: config.apiPort, grpcPort: config.grpcPort }));

  return { app, registry, health, voiceServer };
}

if (require.main === module) {
  main().catch((error) => {
    console.error(JSON.stringify({ event: 'voice_service_failed', error: error.message }));
    process.exitCode = 1;
  });
}

module.exports = { main };
