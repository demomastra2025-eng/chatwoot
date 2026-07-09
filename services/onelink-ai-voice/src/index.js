const { OnelinkClient } = require('./onelink/client');
const { SessionRegistry } = require('./sessions/session-registry');
const { GeminiLiveClient } = require('./realtime/gemini-live-client');
const { VoiceApplication } = require('./app/voice-application');
const { createHealthServer } = require('./diagnostics/health-server');
const { JanusAdminClient } = require('./janus/admin-client');
const { createJanusInternalHandler } = require('./janus/internal-server');
const { createJanusRuntimeMediaStreamFactory } = require('./janus/runtime-stream');
const { JanusRtpRuntimeBridgeManager, createJanusRtpBridgeMediaStreamFactory } = require('./janus/rtp-runtime-bridge');
const { JanusBrowserBridgeManager, createJanusBrowserBridgeMediaStreamFactory } = require('./janus/browser-bridge');
const { JanusSipRtpForwardController } = require('./janus/rtp-forward');
const { JanusMediaServerClient, JanusSipServerRuntimeManager } = require('./janus/server-runtime');
const { createWhatsappInternalHandler } = require('./whatsapp/internal-server');
const { createWhatsappRuntimeMediaStreamFactory } = require('./whatsapp/runtime-stream');
const { loadConfig } = require('./config');

async function main() {
  const config = loadConfig();
  const janusRtpBridgeManager = createJanusRtpBridgeManager(config);
  const janusBrowserBridgeManager = createJanusBrowserBridgeManager(config);
  const client = new OnelinkClient({
    baseUrl: config.railsBaseUrl,
    token: config.internalToken,
    bridgeToken: config.bridgeToken,
    timeoutMs: config.onelinkTimeoutMs,
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
    contextBootstrapTimeoutMs: config.contextBootstrapTimeoutMs,
    mediaStreamFactory: createCompositeMediaStreamFactory([
      createJanusRtpBridgeMediaStreamFactory({ manager: janusRtpBridgeManager }),
      createJanusBrowserBridgeMediaStreamFactory({ manager: janusBrowserBridgeManager }),
      createJanusRuntimeMediaStreamFactory(),
      createWhatsappRuntimeMediaStreamFactory()
    ]),
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

  const janusServerRuntime = createJanusServerRuntimeManager({ config, app, client });
  const health = createHealthServer({
    registry,
    port: config.apiPort,
    diagnostics: () => ({
      janus_server_runtime: janusServerRuntimeDiagnostics(janusServerRuntime)
    }),
    handlers: [
      createJanusInternalHandler({
        app,
        internalToken: config.internalToken,
        path: config.janusAttachPath,
        rtpForwardController: createJanusRtpForwardController(config),
        rtpBridgeManager: janusRtpBridgeManager,
        browserBridgeManager: janusBrowserBridgeManager,
        allowedProviders: config.janusAllowedProviders
      }),
      createWhatsappInternalHandler({
        app,
        internalToken: config.internalToken,
        path: config.whatsappAttachPath
      })
    ],
    upgradeHandlers: [
      janusBrowserBridgeManager ? janusBrowserBridgeManager.handleUpgrade.bind(janusBrowserBridgeManager) : null
    ].filter(Boolean)
  });
  const runtime = { app, registry, health, janusServerRuntime };
  if (require.main === module) installShutdownHandlers(runtime);
  await health.listen();
  try {
    if (janusServerRuntime) await janusServerRuntime.start();
  } catch (error) {
    await health.close();
    throw error;
  }
  if (janusServerRuntime?.closed) return runtime;

  console.log(JSON.stringify({ event: 'voice_service_started', apiPort: config.apiPort }));

  return runtime;
}

if (require.main === module) {
  main().catch((error) => {
    console.error(JSON.stringify({ event: 'voice_service_failed', error: error.message }));
    process.exitCode = 1;
  });
}

module.exports = { main };

function createCompositeMediaStreamFactory(factories = []) {
  const activeFactories = factories.filter(factory => typeof factory === 'function');
  return async function compositeMediaStreamFactory(call) {
    for (const factory of activeFactories) {
      const stream = await factory(call);
      if (stream) return stream;
    }
    return null;
  };
}

module.exports.createCompositeMediaStreamFactory = createCompositeMediaStreamFactory;

function createJanusRtpForwardController(config = {}) {
  if (!config.janusAdminUrl) return null;
  return new JanusSipRtpForwardController({
    client: new JanusAdminClient({
      baseUrl: config.janusAdminUrl,
      adminSecret: config.janusAdminSecret
    }),
    adminKey: config.janusSipAdminKey,
    defaultHost: config.janusRtpForwardHost,
    defaultHostFamily: config.janusRtpForwardHostFamily,
    defaultPeerAudioPort: config.janusRtpForwardPeerAudioPort,
    defaultAudioPort: config.janusRtpForwardAudioPort,
    defaultPayloadType: config.janusRtpForwardPayloadType
  });
}

module.exports.createJanusRtpForwardController = createJanusRtpForwardController;

function createJanusRtpBridgeManager(config = {}) {
  if (!config.janusRtpBridgeEnabled) return null;
  return new JanusRtpRuntimeBridgeManager({
    enabled: true,
    listenHost: config.janusRtpBridgeListenHost,
    listenPort: config.janusRtpBridgeListenPort,
    publicHost: config.janusRtpBridgePublicHost,
    inputCodec: config.janusRtpBridgeInputCodec,
    outputCodec: config.janusRtpBridgeOutputCodec,
    outputHost: config.janusRtpBridgeOutputHost,
    outputPort: config.janusRtpBridgeOutputPort,
    outputPayloadType: config.janusRtpBridgeOutputPayloadType
  });
}

module.exports.createJanusRtpBridgeManager = createJanusRtpBridgeManager;

function createJanusBrowserBridgeManager(config = {}) {
  if (!config.janusBrowserBridgeEnabled) return null;
  return new JanusBrowserBridgeManager({
    path: config.janusBrowserBridgePath,
    publicBaseUrl: config.janusBrowserBridgePublicBaseUrl
  });
}

module.exports.createJanusBrowserBridgeManager = createJanusBrowserBridgeManager;

function createJanusServerRuntimeManager({ config = {}, app, client } = {}) {
  if (!config.janusServerRuntimeEnabled) return null;
  const staticProfiles = Array.isArray(config.janusServerProfiles) ? config.janusServerProfiles : [];
  return new JanusSipServerRuntimeManager({
    app,
    profiles: staticProfiles,
    janusUrl: config.janusServerWsUrl,
    mediaServerClient: new JanusMediaServerClient({
      baseUrl: config.janusMediaServerUrl,
      token: config.janusMediaServerToken,
      timeoutMs: config.onelinkTimeoutMs
    }),
    profileProvider: config.janusServerProfilesPath && client
      ? async () => applyJanusServerProviderUrls(await client.getJanusSipProfiles({ path: config.janusServerProfilesPath }), config)
      : null,
    syncIntervalMs: config.janusServerProfileSyncIntervalMs,
    maxCallsPerProfile: config.janusServerMaxCallsPerProfile,
    registrationConcurrency: config.janusServerRegistrationConcurrency
  });
}

module.exports.createJanusServerRuntimeManager = createJanusServerRuntimeManager;

function applyJanusServerProviderUrls(profiles = [], config = {}) {
  const providerUrls = config.janusServerProviderWsUrls || {};
  return profiles.map(profile => {
    const provider = String(profile.provider || '').trim().toLowerCase();
    const janusUrl = profile.janus_url || profile.janusUrl || providerUrls[provider] || config.janusServerWsUrl;
    return janusUrl ? { ...profile, janus_url: janusUrl } : profile;
  });
}

module.exports.applyJanusServerProviderUrls = applyJanusServerProviderUrls;

function janusServerRuntimeDiagnostics(runtime) {
  if (!runtime) return { enabled: false };
  return runtime.diagnostics();
}

module.exports.janusServerRuntimeDiagnostics = janusServerRuntimeDiagnostics;

function installShutdownHandlers(runtime = {}) {
  let stopping = false;
  const shutdown = async signal => {
    if (stopping) return;
    stopping = true;
    console.log(JSON.stringify({ event: 'voice_service_stopping', signal }));
    await runtime.janusServerRuntime?.close?.();
    await runtime.health?.close?.();
  };
  process.once('SIGTERM', () => { void shutdown('SIGTERM'); });
  process.once('SIGINT', () => { void shutdown('SIGINT'); });
}

module.exports.installShutdownHandlers = installShutdownHandlers;
