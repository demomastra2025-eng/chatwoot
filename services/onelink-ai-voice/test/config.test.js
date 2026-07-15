const test = require('node:test');
const assert = require('node:assert/strict');
const { loadConfig } = require('../src/config');

test('loadConfig defaults to Gemini Live with production voice model and sulafat voice', () => {
  const config = loadConfig({});

  assert.equal(config.realtimeProvider, 'gemini-live');
  assert.equal(config.geminiModel, 'gemini-3.1-flash-live-preview');
  assert.equal(config.geminiVoice, 'sulafat');
  assert.equal(config.language, 'ru-KZ');
  assert.equal(config.toolTimeoutMs, 3_000);
  assert.equal(config.onelinkTimeoutMs, 10_000);
  assert.equal(config.contextBootstrapTimeoutMs, 2_500);
  assert.equal(config.janusAttachPath, '/internal/janus-sip/calls');
  assert.deepEqual(config.janusAllowedProviders, []);
  assert.equal(config.janusAdminUrl, '');
  assert.equal(config.janusRtpForwardHostFamily, 'ipv4');
  assert.equal(config.janusRtpForwardPeerAudioPort, 0);
  assert.equal(config.janusRtpBridgeEnabled, false);
  assert.equal(config.janusRtpBridgeListenHost, '0.0.0.0');
  assert.equal(config.janusRtpBridgeListenPort, 0);
  assert.equal(config.janusBrowserBridgeEnabled, false);
  assert.equal(config.janusBrowserBridgePath, '/ai-voice/janus-sip/browser-media');
  assert.equal(config.janusBrowserBridgePublicBaseUrl, '');
  assert.deepEqual(config.janusBrowserBridgeAllowedOrigins, []);
  assert.equal(config.janusBrowserBridgeMaxPayloadBytes, 128 * 1024);
  assert.equal(config.janusBrowserBridgeMaxAudioBytes, 64 * 1024);
  assert.equal(config.janusBrowserBridgeMaxSessions, 256);
  assert.equal(config.janusServerRuntimeEnabled, false);
  assert.equal(config.janusServerWsUrl, '');
  assert.deepEqual(config.janusServerProfiles, []);
  assert.equal(config.janusServerProfilesPath, '/internal/voice/ai/janus-sip/profiles');
  assert.equal(config.janusServerProfileSyncIntervalMs, 15_000);
  assert.deepEqual(config.janusServerProviderWsUrls, { sipuni: '', binotel: '', asterisk_analog: '' });
  assert.equal(config.janusMediaServerUrl, '');
  assert.equal(config.janusMediaServerToken, '');
  assert.equal(config.outputMaxBufferedMs, 15_000);
  assert.equal(config.postToolContinuationMs, 4_000);
  assert.equal(config.clearAudioOnInterrupt, false);
  assert.equal(config.interruptionMode, 'transcript_confirmed');
});

test('loadConfig prefers AI voice internal token while preserving legacy fallback', () => {
  assert.equal(
    loadConfig({ ONELINK_AI_VOICE_INTERNAL_TOKEN: 'voice-token', ONELINK_INTERNAL_TOKEN: 'legacy-token' }).internalToken,
    'voice-token'
  );
  assert.equal(
    loadConfig({ VOICE_AGENT_ONELINK_AI_SHARED_SECRET: 'contract-token', ONELINK_AI_VOICE_INTERNAL_TOKEN: 'voice-token' }).internalToken,
    'voice-token'
  );
  assert.equal(loadConfig({ AI_VOICE_INTERNAL_TOKEN: 'short-token' }).internalToken, 'short-token');
  assert.equal(loadConfig({ ONELINK_INTERNAL_TOKEN: 'legacy-token' }).internalToken, 'legacy-token');
});

test('loadConfig keeps bridge token separate from AI voice token', () => {
  const config = loadConfig({
    ONELINK_AI_VOICE_INTERNAL_TOKEN: 'ai-token',
    TELEPHONY_BRIDGE_ONELINK_ACCESS_TOKEN: 'bridge-token'
  });

  assert.equal(config.internalToken, 'ai-token');
  assert.equal(config.bridgeToken, 'bridge-token');
});

test('loadConfig uses a longer bounded Onelink HTTP timeout for slow voice context bootstrap', () => {
  assert.equal(loadConfig({ VOICE_AGENT_ONELINK_TIMEOUT_MS: '12000' }).onelinkTimeoutMs, 12_000);
  assert.equal(loadConfig({ VOICE_AGENT_ONELINK_AI_TIMEOUT_MS: '9000' }).onelinkTimeoutMs, 9_000);
  assert.equal(loadConfig({ VOICE_AGENT_CONTEXT_BOOTSTRAP_TIMEOUT_MS: '500' }).contextBootstrapTimeoutMs, 500);
  assert.equal(loadConfig({ VOICE_AGENT_CONTEXT_TIMEOUT_MS: '600' }).contextBootstrapTimeoutMs, 600);
});

test('loadConfig accepts AI voice env aliases for Rails and realtime tuning', () => {
  const config = loadConfig({
    VOICE_AGENT_ONELINK_AI_BASE_URL: 'http://rails:3000/',
    VOICE_AGENT_ONELINK_AI_EVENT_PATH: '/custom/event',
    VOICE_AGENT_ONELINK_AI_FINALIZE_PATH: '/custom/finalize',
    VOICE_AGENT_JANUS_ATTACH_PATH: '/custom/janus/calls',
    VOICE_AGENT_JANUS_ALLOWED_PROVIDERS: 'sipuni, asterisk_analog',
    VOICE_AGENT_JANUS_ADMIN_URL: 'http://janus:7088',
    VOICE_AGENT_JANUS_ADMIN_SECRET: 'admin-secret',
    VOICE_AGENT_JANUS_SIP_ADMIN_KEY: 'sip-admin-key',
    VOICE_AGENT_JANUS_RTP_FORWARD_HOST: 'janus-ai-gateway',
    VOICE_AGENT_JANUS_RTP_FORWARD_HOST_FAMILY: 'ipv6',
    VOICE_AGENT_JANUS_RTP_FORWARD_PEER_AUDIO_PORT: '40000',
    VOICE_AGENT_JANUS_RTP_FORWARD_AUDIO_PORT: '40002',
    VOICE_AGENT_JANUS_RTP_FORWARD_PAYLOAD_TYPE: '8',
    VOICE_AGENT_JANUS_RTP_BRIDGE_ENABLED: 'true',
    VOICE_AGENT_JANUS_RTP_BRIDGE_LISTEN_HOST: '0.0.0.0',
    VOICE_AGENT_JANUS_RTP_BRIDGE_LISTEN_PORT: '40000',
    VOICE_AGENT_JANUS_RTP_BRIDGE_PUBLIC_HOST: 'onelink_ai_voice',
    VOICE_AGENT_JANUS_RTP_BRIDGE_INPUT_CODEC: 'pcma',
    VOICE_AGENT_JANUS_RTP_BRIDGE_OUTPUT_CODEC: 'pcmu',
    VOICE_AGENT_JANUS_RTP_BRIDGE_OUTPUT_HOST: 'janus-nostip-input',
    VOICE_AGENT_JANUS_RTP_BRIDGE_OUTPUT_PORT: '41000',
    VOICE_AGENT_JANUS_RTP_BRIDGE_OUTPUT_PAYLOAD_TYPE: '0',
    VOICE_AGENT_JANUS_BROWSER_BRIDGE_ENABLED: 'true',
    VOICE_AGENT_JANUS_BROWSER_BRIDGE_PATH: '/custom/browser-media',
    VOICE_AGENT_JANUS_BROWSER_BRIDGE_ALLOWED_ORIGINS: 'https://app.one-link.kz, https://dev.one-link.kz',
    VOICE_AGENT_JANUS_BROWSER_BRIDGE_MAX_PAYLOAD_BYTES: '65536',
    VOICE_AGENT_JANUS_BROWSER_BRIDGE_MAX_AUDIO_BYTES: '32768',
    VOICE_AGENT_JANUS_BROWSER_BRIDGE_MAX_SESSIONS: '64',
    VOICE_AGENT_JANUS_BROWSER_BRIDGE_ATTACH_TIMEOUT_MS: '45000',
    VOICE_AGENT_JANUS_BROWSER_BRIDGE_IDLE_TIMEOUT_MS: '15000',
    VOICE_AGENT_JANUS_SERVER_RUNTIME_ENABLED: 'true',
    VOICE_AGENT_JANUS_SERVER_WS_URL: 'ws://janus:8188',
    VOICE_AGENT_JANUS_SERVER_PROFILES_JSON: '[{"id":12,"provider":"sipuni"}]',
    VOICE_AGENT_JANUS_SERVER_PROFILES_PATH: '/custom/janus/profiles',
    VOICE_AGENT_JANUS_SERVER_PROFILE_SYNC_INTERVAL_MS: '5000',
    VOICE_AGENT_JANUS_SERVER_MAX_CALLS_PER_PROFILE: '6',
    VOICE_AGENT_JANUS_SERVER_REGISTRATION_CONCURRENCY: '12',
    VOICE_AGENT_JANUS_SERVER_SIPUNI_WS_URL: 'ws://janus-sipuni:8188',
    VOICE_AGENT_JANUS_SERVER_BINOTEL_WS_URL: 'ws://janus-binotel:8188',
    VOICE_AGENT_JANUS_SERVER_ASTERISK_ANALOG_WS_URL: 'ws://janus-asterisk:8189',
    VOICE_AGENT_JANUS_MEDIA_SERVER_URL: 'http://media-server:4000/',
    VOICE_AGENT_JANUS_MEDIA_SERVER_TOKEN: 'media-token',
    VOICE_AGENT_PUBLIC_BASE_URL: 'wss://dev.one-link.kz/',
    VOICE_AGENT_WHATSAPP_ATTACH_PATH: '/custom/whatsapp/calls',
    VOICE_AGENT_REALTIME_OUTPUT_MAX_BUFFERED_MS: '1500',
    VOICE_AGENT_REALTIME_POST_TOOL_CONTINUATION_MS: '2500',
    VOICE_AGENT_REALTIME_VAD_PREFIX_PADDING_MS: '140',
    VOICE_AGENT_REALTIME_VAD_SILENCE_DURATION_MS: '320',
    VOICE_AGENT_REALTIME_VAD_START_SENSITIVITY: 'START_SENSITIVITY_LOW',
    VOICE_AGENT_REALTIME_VAD_END_SENSITIVITY: 'END_SENSITIVITY_LOW',
    VOICE_AGENT_REALTIME_TURN_COVERAGE: 'TURN_INCLUDES_ALL_INPUT',
    VOICE_AGENT_REALTIME_INTERRUPTION_MODE: 'provider'
  });

  assert.equal(config.railsBaseUrl, 'http://rails:3000');
  assert.equal(config.eventPath, '/custom/event');
  assert.equal(config.finalizePath, '/custom/finalize');
  assert.equal(config.janusAttachPath, '/custom/janus/calls');
  assert.deepEqual(config.janusAllowedProviders, ['sipuni', 'asterisk_analog']);
  assert.equal(config.janusAdminUrl, 'http://janus:7088');
  assert.equal(config.janusAdminSecret, 'admin-secret');
  assert.equal(config.janusSipAdminKey, 'sip-admin-key');
  assert.equal(config.janusRtpForwardHost, 'janus-ai-gateway');
  assert.equal(config.janusRtpForwardHostFamily, 'ipv6');
  assert.equal(config.janusRtpForwardPeerAudioPort, 40000);
  assert.equal(config.janusRtpForwardAudioPort, 40002);
  assert.equal(config.janusRtpForwardPayloadType, 8);
  assert.equal(config.janusRtpBridgeEnabled, true);
  assert.equal(config.janusRtpBridgeListenHost, '0.0.0.0');
  assert.equal(config.janusRtpBridgeListenPort, 40000);
  assert.equal(config.janusRtpBridgePublicHost, 'onelink_ai_voice');
  assert.equal(config.janusRtpBridgeInputCodec, 'pcma');
  assert.equal(config.janusRtpBridgeOutputCodec, 'pcmu');
  assert.equal(config.janusRtpBridgeOutputHost, 'janus-nostip-input');
  assert.equal(config.janusRtpBridgeOutputPort, 41000);
  assert.equal(config.janusRtpBridgeOutputPayloadType, 0);
  assert.equal(config.janusBrowserBridgeEnabled, true);
  assert.equal(config.janusBrowserBridgePath, '/custom/browser-media');
  assert.equal(config.janusBrowserBridgePublicBaseUrl, 'wss://dev.one-link.kz');
  assert.deepEqual(config.janusBrowserBridgeAllowedOrigins, [
    'https://app.one-link.kz',
    'https://dev.one-link.kz'
  ]);
  assert.equal(config.janusBrowserBridgeMaxPayloadBytes, 65536);
  assert.equal(config.janusBrowserBridgeMaxAudioBytes, 32768);
  assert.equal(config.janusBrowserBridgeMaxSessions, 64);
  assert.equal(config.janusBrowserBridgeAttachTimeoutMs, 45000);
  assert.equal(config.janusBrowserBridgeIdleTimeoutMs, 15000);
  assert.equal(config.janusServerRuntimeEnabled, true);
  assert.equal(config.janusServerWsUrl, 'ws://janus:8188');
  assert.deepEqual(config.janusServerProfiles, [{ id: 12, provider: 'sipuni' }]);
  assert.equal(config.janusServerProfilesPath, '/custom/janus/profiles');
  assert.equal(config.janusServerProfileSyncIntervalMs, 5000);
  assert.equal(config.janusServerMaxCallsPerProfile, 6);
  assert.equal(config.janusServerRegistrationConcurrency, 12);
  assert.deepEqual(config.janusServerProviderWsUrls, {
    sipuni: 'ws://janus-sipuni:8188',
    binotel: 'ws://janus-binotel:8188',
    asterisk_analog: 'ws://janus-asterisk:8189'
  });
  assert.equal(config.janusMediaServerUrl, 'http://media-server:4000');
  assert.equal(config.janusMediaServerToken, 'media-token');
  assert.equal(config.whatsappAttachPath, '/custom/whatsapp/calls');
  assert.equal(config.outputMaxBufferedMs, 1500);
  assert.equal(config.postToolContinuationMs, 2500);
  assert.equal(config.prefixPaddingMs, 140);
  assert.equal(config.silenceDurationMs, 320);
  assert.equal(config.speechStartSensitivity, 'START_SENSITIVITY_LOW');
  assert.equal(config.speechEndSensitivity, 'END_SENSITIVITY_LOW');
  assert.equal(config.turnCoverage, 'TURN_INCLUDES_ALL_INPUT');
  assert.equal(config.interruptionMode, 'provider');
});
