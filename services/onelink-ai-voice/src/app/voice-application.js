const { VoiceSession } = require('../sessions/voice-session');
const { ScriptedFallbackResponder } = require('../realtime/scripted-fallback');

const streamConstants = loadStreamConstants();

class VoiceApplication {
  constructor({ client, registry = null, realtimeFactory = null, fallbackResponder = new ScriptedFallbackResponder(), mediaStreamFactory = null } = {}) {
    if (!client) throw new Error('client is required');
    this.client = client;
    this.registry = registry;
    this.realtimeFactory = realtimeFactory;
    this.fallbackResponder = fallbackResponder;
    this.mediaStreamFactory = mediaStreamFactory;
  }

  async handleCall(call, payload = {}) {
    const requestPayload = normalizeCallPayload(call, payload);
    const callRef = requestPayload.call_ref || requestPayload.callRef || requestPayload.ref || requestPayload.sessionId || `call-${Date.now()}`;
    const session = new VoiceSession({
      client: this.client,
      callRef,
      ingressNumber: requestPayload.ingress_number || requestPayload.to,
      callerNumber: requestPayload.caller_number || requestPayload.from,
      numberRef: requestPayload.number_ref,
      accountId: requestPayload.account_id
    });
    this.registry?.create({ callRef, context: {}, accountId: requestPayload.account_id });
    await answerCall(call);

    const context = await session.bootstrap();
    this.registry?.update?.(callRef, { context, state: session.state });

    if (session.state === 'fallback') {
      await this.fallbackResponder.greet(call);
      return { session, context, mode: 'fallback', completion: Promise.resolve() };
    }

    let bridge;
    try {
      bridge = await this.startRealtimeBridge(call, session, context, requestPayload);
    } catch (error) {
      const reason = sanitizeReason(error?.message || 'realtime_unavailable');
      session.state = 'fallback';
      await session.safeControl('session_failed', { reason });
      await this.fallbackResponder.greet(call);
      return { session, context, mode: 'fallback', completion: Promise.resolve(), reason };
    }
    return { session, context, realtime: bridge.realtime, mediaStream: bridge.mediaStream, mode: 'realtime', completion: bridge.completion };
  }

  async startRealtimeBridge(call, session, context, requestPayload = {}) {
    const mediaStream = await this.startMediaStream(call);
    let streamRef = mediaStream?.streamRef || requestPayload.stream_ref || requestPayload.media_session_ref || '';
    const mediaSessionRef = requestPayload.media_session_ref || requestPayload.mediaSessionRef || call?.request?.mediaSessionRef || session.callRef;

    const callbacks = {
      systemPrompt: buildSystemPrompt(context),
      tools: normalizeContextTools(context.tools),
      onAudio: (chunk, metadata = {}) => {
        if (!mediaStream || !chunk) return;
        mediaStream.write({
          mediaSessionRef,
          streamRef,
          format: streamConstants.wavFormat,
          type: streamConstants.audioOut,
          data: Buffer.isBuffer(chunk) ? chunk : Buffer.from(chunk),
          ...(metadata.mimeType ? { mimeType: metadata.mimeType } : {})
        });
      },
      onTranscript: item => {
        const speaker = normalizeSpeaker(item.speaker);
        if (speaker === 'caller') {
          session.recordCallerTranscript(item.text, { final: item.final !== false, provider: item.provider, at: item.at });
        } else {
          session.recordAiTranscript(item.text, { final: item.final !== false, provider: item.provider, at: item.at });
        }
      },
      onToolCall: callPayload => session.executeTool(callPayload.name, callPayload.args || {}, {
        provider: 'gemini-live',
        tool_call_id: callPayload.id
      }),
      onInterrupt: async () => {
        await session.safeControl('caller_interrupted', { provider: 'gemini-live' });
      }
    };

    const realtime = this.realtimeFactory ? this.realtimeFactory({ session, context, ...callbacks }) : null;
    if (!realtime || typeof realtime.connect !== 'function') {
      throw new Error('realtime client is required');
    }

    wireMediaInput(mediaStream, payload => {
      if (!payload || !payload.data || !isAudioIn(payload.type)) return;
      streamRef = payload.streamRef || streamRef;
      realtime.sendAudio(Buffer.from(payload.data), {
        mimeType: mimeTypeForStreamPayload(payload)
      });
    });

    const completion = buildCompletion({ call, mediaStream, realtime, session, registry: this.registry });
    try {
      await realtime.connect(callbacks);
    } catch (error) {
      try {
        realtime?.close?.();
      } catch (_closeError) {
        // ignore cleanup errors
      }
      try {
        mediaStream?.close?.();
      } catch (_closeError) {
        // ignore cleanup errors
      }
      throw error;
    }
    return { realtime, mediaStream, completion };
  }

  async startMediaStream(call) {
    if (this.mediaStreamFactory) {
      return this.mediaStreamFactory(call);
    }
    if (!call || typeof call.stream !== 'function') {
      return null;
    }
    return call.stream({
      direction: streamConstants.bothDirection,
      format: streamConstants.wavFormat
    });
  }
}

function wireMediaInput(mediaStream, handler) {
  if (!mediaStream) return;
  if (typeof mediaStream.onPayload === 'function') {
    mediaStream.onPayload(handler);
    return;
  }
  if (typeof mediaStream.on === 'function') {
    mediaStream.on('payload', handler);
    mediaStream.on('payloadOut', handler);
  }
}

function buildCompletion({ call, mediaStream, realtime, session, registry }) {
  return new Promise(resolve => {
    let completed = false;
    const finish = async action => {
      if (completed) return;
      completed = true;
      try {
        realtime?.close?.();
      } catch (_error) {
        // ignore close errors
      }
      try {
        await session.close(action || 'session_completed');
      } catch (_error) {
        // transcript/control persistence errors should not block media cleanup
      }
      registry?.update?.(session.callRef, { state: session.state });
      resolve();
    };

    let registered = false;
    registered = registerCallCompletion(call, finish) || registered;

    if (mediaStream) {
      if (typeof mediaStream.cleanup === 'function') {
        mediaStream.cleanup(() => { void finish('session_completed'); });
        registered = true;
      }

      if (typeof mediaStream.on === 'function' || typeof mediaStream.once === 'function') {
        registered = registerStreamCompletion(mediaStream, finish) || registered;
      }
    }

    if (!registered) {
      resolve();
    }
  });
}

function registerCallCompletion(call, finish) {
  const targets = [call, call?.voice].filter(Boolean);
  let registered = false;
  for (const target of targets) {
    for (const eventName of callEndEvents()) {
      registered = registerOnce(target, eventName, () => { void finish('session_completed'); }) || registered;
    }
    for (const eventName of callErrorEvents()) {
      registered = registerOnce(target, eventName, () => { void finish('session_failed'); }) || registered;
    }
  }
  return registered;
}

function registerStreamCompletion(mediaStream, finish) {
  let registered = false;
  for (const eventName of ['end', 'close', 'END', 'CLOSE']) {
    registered = registerOnce(mediaStream, eventName, () => { void finish('session_completed'); }) || registered;
  }
  for (const eventName of ['error', 'ERROR']) {
    registered = registerOnce(mediaStream, eventName, () => { void finish('session_failed'); }) || registered;
  }
  return registered;
}

function registerOnce(target, eventName, handler) {
  if (!target || !eventName) return false;
  if (typeof target.once === 'function') {
    target.once(eventName, handler);
    return true;
  }
  if (typeof target.on === 'function') {
    const wrapped = (...args) => {
      if (typeof target.off === 'function') target.off(eventName, wrapped);
      if (typeof target.removeListener === 'function') target.removeListener(eventName, wrapped);
      handler(...args);
    };
    target.on(eventName, wrapped);
    return true;
  }
  return false;
}

function callEndEvents() {
  const events = ['end', 'close', 'hangup', 'completed', 'END', 'CLOSE'];
  try {
    const common = require('@fonoster/common');
    if (common.StreamEvent?.END) events.unshift(common.StreamEvent.END);
  } catch (_error) {
    // @fonoster/common is optional in tests
  }
  return [...new Set(events)];
}

function callErrorEvents() {
  const events = ['error', 'failed', 'ERROR', 'FAILED'];
  try {
    const common = require('@fonoster/common');
    if (common.StreamEvent?.ERROR) events.unshift(common.StreamEvent.ERROR);
  } catch (_error) {
    // @fonoster/common is optional in tests
  }
  return [...new Set(events)];
}

function buildSystemPrompt(context = {}) {
  const pieces = [
    context.system_prompt,
    context.prompt,
    context.ai?.system_prompt,
    context.ai?.instructions,
    context.ai?.first_message ? `Начни разговор коротко: ${context.ai.first_message}` : null
  ].filter(Boolean);
  return pieces.join('\n\n');
}

function normalizeContextTools(tools) {
  return (Array.isArray(tools) ? tools : [])
    .filter(tool => tool && tool.name && tool.enabled !== false)
    .map(tool => ({
      name: tool.name,
      description: tool.description || tool.summary || `OneLink tool ${tool.name}`,
      parameters: tool.parameters || tool.schema || { type: 'object', properties: {} }
    }));
}

function normalizeSpeaker(speaker) {
  const value = String(speaker || '').toLowerCase();
  return ['caller', 'customer', 'user', 'human'].includes(value) ? 'caller' : 'ai';
}

function isAudioIn(type) {
  return [streamConstants.audioIn, 'audio_in', 'AUDIO_IN', 'in'].includes(type);
}

function mimeTypeForStreamPayload(payload) {
  if (payload.mimeType) return payload.mimeType;
  return 'audio/pcm;rate=16000';
}

function normalizeCallPayload(call, payload = {}) {
  const request = call?.request || {};
  return {
    ...request,
    ...payload,
    call_ref: payload.call_ref || payload.callRef || request.call_ref || request.callRef,
    media_session_ref: payload.media_session_ref || payload.mediaSessionRef || request.media_session_ref || request.mediaSessionRef,
    ingress_number: payload.ingress_number || payload.to || request.ingress_number || request.to,
    caller_number: payload.caller_number || payload.from || request.caller_number || request.from
  };
}

function answerCall(call) {
  if (!call || typeof call.answer !== 'function') return Promise.resolve(false);
  return Promise.resolve(call.answer()).then(() => true);
}

function sanitizeReason(message) {
  return String(message || 'realtime_unavailable').replace(/(key|token|secret|password)=([^\s&]+)/gi, '$1=[REDACTED]');
}

function loadStreamConstants() {
  try {
    const common = require('@fonoster/common');
    return {
      audioIn: common.StreamMessageType?.AUDIO_IN || 'audio_in',
      audioOut: common.StreamMessageType?.AUDIO_OUT || 'audio_out',
      wavFormat: common.StreamAudioFormat?.WAV || 'wav',
      bothDirection: common.StreamDirection?.BOTH || 'both'
    };
  } catch (_error) {
    return {
      audioIn: 'audio_in',
      audioOut: 'audio_out',
      wavFormat: 'wav',
      bothDirection: 'both'
    };
  }
}

module.exports = { VoiceApplication, buildSystemPrompt, normalizeContextTools, normalizeCallPayload };
