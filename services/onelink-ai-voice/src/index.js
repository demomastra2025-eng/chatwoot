const { OnelinkClient } = require('./onelink/client');
const { SessionRegistry } = require('./sessions/session-registry');
const { GeminiLiveClient } = require('./realtime/gemini-live-client');
const { VoiceApplication } = require('./app/voice-application');
const { createHealthServer } = require('./diagnostics/health-server');
const { startFonosterVoiceServer } = require('./fonoster/server');
const { loadConfig } = require('./config');

async function main() {
  const config = loadConfig();
  const client = new OnelinkClient({
    baseUrl: config.railsBaseUrl,
    token: config.internalToken,
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
    realtimeFactory: ({ context, onAudio, onTranscript, onToolCall, onInterrupt, onEvent }) => new GeminiLiveClient({
      apiKey: config.geminiApiKey,
      model: context.ai?.model || config.geminiModel,
      voice: context.ai?.voice || config.geminiVoice,
      language: context.ai?.language || config.language,
      temperature: context.ai?.temperature ?? config.temperature,
      maxOutputTokens: context.ai?.max_output_tokens || context.ai?.maxOutputTokens || config.maxOutputTokens,
      setupTimeoutMs: config.setupTimeoutMs,
      interruptions: config.interruptions,
      speechStartSensitivity: config.speechStartSensitivity,
      speechEndSensitivity: config.speechEndSensitivity,
      prefixPaddingMs: config.prefixPaddingMs,
      silenceDurationMs: config.silenceDurationMs,
      turnCoverage: config.turnCoverage,
      onAudio,
      onTranscript,
      onToolCall,
      onInterrupt,
      onEvent
    })
  });

  const health = createHealthServer({ registry, port: config.apiPort });
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
