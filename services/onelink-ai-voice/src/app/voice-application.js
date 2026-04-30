const { VoiceSession } = require('../sessions/voice-session');
const { ScriptedFallbackResponder } = require('../realtime/scripted-fallback');

const streamConstants = loadStreamConstants();
const FONOSTER_INPUT_RATE = parseStreamRate(process.env.VOICE_AGENT_REALTIME_INPUT_RATE, 16_000);
const FONOSTER_CALL_RATE = parseStreamRate(process.env.VOICE_AGENT_REALTIME_CALL_RATE, 8_000);
const GEMINI_OUTPUT_RATE = parseStreamRate(process.env.VOICE_AGENT_REALTIME_OUTPUT_RATE, 24_000);

class VoiceApplication {
  constructor({ client, registry = null, realtimeFactory = null, fallbackResponder = new ScriptedFallbackResponder(), mediaStreamFactory = null, toolTimeoutMs = 3_000 } = {}) {
    if (!client) throw new Error('client is required');
    this.client = client;
    this.registry = registry;
    this.realtimeFactory = realtimeFactory;
    this.fallbackResponder = fallbackResponder;
    this.mediaStreamFactory = mediaStreamFactory;
    this.toolTimeoutMs = toolTimeoutMs;
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
      accountId: requestPayload.account_id,
      toolTimeoutMs: this.toolTimeoutMs
    });
    this.registry?.create({ callRef, context: {}, accountId: requestPayload.account_id });

    const routeDecision = await this.routeInboundSafely(requestPayload, callRef);
    applyRouteScope(session, routeDecision);
    await this.safeBridgeEvent('session_started', session, requestPayload, routeDecision);
    const routeAction = normalizeRouteAction(routeDecision);
    const handleLocallyAsAi = shouldHandleAppRouteLocally(routeDecision, requestPayload);

    if (routeAction === 'operator') {
      await answerCall(call);
      await this.safeBridgeEvent('operator_ringing', session, requestPayload, routeDecision);
      try {
        const dialResult = await dialOperator(call, routeDecision);
        if (dialResult === false) {
          const completion = this.handleOperatorFailure(call, session, requestPayload, routeDecision, 'operator_dial_unavailable');
          return { session, decision: routeDecision, mode: 'operator', completion };
        }
        this.registry?.update?.(callRef, { routeDecision, state: 'operator' });
        const completion = buildOperatorCompletion({
          call,
          dialResult,
          session,
          requestPayload,
          routeDecision,
          app: this,
          registry: this.registry
        });
        return { session, decision: routeDecision, mode: 'operator', completion };
      } catch (error) {
        const reason = sanitizeReason(error?.message || 'operator_dial_failed');
        const completion = this.handleOperatorFailure(call, session, requestPayload, routeDecision, reason);
        return { session, decision: routeDecision, mode: 'operator', completion, reason };
      }
    }

    if (routeAction === 'reject') {
      await this.safeBridgeEvent('session_failed', session, requestPayload, routeDecision, { reason: routeDecision.reason || 'route_rejected' });
      await rejectCall(call, routeDecision);
      this.registry?.update?.(callRef, { routeDecision, state: 'rejected' });
      return { session, decision: routeDecision, mode: 'reject', completion: Promise.resolve() };
    }

    if (routeAction === 'app' && !handleLocallyAsAi) {
      await answerCall(call);
      await this.safeBridgeEvent('app_routing', session, requestPayload, routeDecision);
      await handoffToApp(call, routeDecision);
      this.registry?.update?.(callRef, { routeDecision, state: 'app' });
      return { session, decision: routeDecision, mode: 'app', completion: Promise.resolve() };
    }

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

  async routeInboundSafely(requestPayload, callRef) {
    try {
      return await this.routeInbound(requestPayload, callRef);
    } catch (error) {
      return routeLookupFailureDecision(error);
    }
  }

  routeInbound(requestPayload, callRef) {
    if (!this.client || typeof this.client.routeInbound !== 'function') {
      throw new Error('client.routeInbound is required');
    }

    return this.client.routeInbound(routePayload(requestPayload, callRef));
  }

  async safeBridgeEvent(event, session, requestPayload, routeDecision = {}, metadata = {}) {
    if (!this.client || typeof this.client.sendBridgeEvent !== 'function') return;

    try {
      await this.client.sendBridgeEvent(bridgeEventPayload(event, session, requestPayload, routeDecision, metadata));
    } catch (_error) {
      // Telephony execution must not be interrupted by transient lifecycle persistence errors.
    }
  }

  async handleOperatorFailure(call, session, requestPayload, routeDecision = {}, reason = 'operator_dial_failed', event = 'operator_failed') {
    await this.safeBridgeEvent(event, session, requestPayload, routeDecision, { reason });

    let finalReason = reason;
    const fallbackDecision = operatorFallbackDecision(routeDecision, reason);
    if (fallbackDecision) {
      await this.safeBridgeEvent('app_routing', session, requestPayload, fallbackDecision, {
        reason,
        operator_failure_event: event
      });
      try {
        const fallbackStarted = await handoffToApp(call, fallbackDecision);
        if (fallbackStarted !== false) {
          this.registry?.update?.(session.callRef, { routeDecision: fallbackDecision, state: 'app' });
          return;
        }
      } catch (error) {
        finalReason = sanitizeReason(error?.message || `${reason}_fallback_failed`);
      }
    }

    await this.safeBridgeEvent('session_failed', session, requestPayload, routeDecision, {
      reason: finalReason,
      original_reason: reason
    });
    try {
      await rejectCall(call, { reason: finalReason });
    } catch (_error) {
      // Best-effort terminal persistence is more important than propagating provider reject errors.
    }
    this.registry?.update?.(session.callRef, { routeDecision, state: 'failed' });
  }

  async startRealtimeBridge(call, session, context, requestPayload = {}) {
    const mediaStream = await this.startMediaStream(call);
    let streamRef = mediaStream?.streamRef || requestPayload.stream_ref || requestPayload.media_session_ref || '';
    const mediaSessionRef = requestPayload.media_session_ref || requestPayload.mediaSessionRef || call?.request?.mediaSessionRef || session.callRef;
    const outputPacer = mediaStream ? new Pcm16FramePacer({
      sampleRate: FONOSTER_CALL_RATE,
      frameMs: 20,
      maxBufferedMs: 15_000,
      onFrame: data => {
        mediaStream.write({
          mediaSessionRef,
          streamRef,
          format: streamConstants.wavFormat,
          type: streamConstants.audioOut,
          data
        });
      }
    }) : null;

    const callbacks = {
      systemPrompt: buildSystemPrompt(context),
      tools: normalizeContextTools(context.tools),
      onAudio: (chunk, metadata = {}) => {
        if (!outputPacer || !chunk) return;
        const data = fonosterAudioChunk(chunk, metadata);
        if (!data.length) return;
        outputPacer.push(data);
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
        if (shouldClearOutputOnInterrupt()) {
          outputPacer?.clear?.();
        }
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

    const completion = buildCompletion({ call, mediaStream, outputPacer, realtime, session, registry: this.registry });
    try {
      await realtime.connect(callbacks);
      sendInitialGreeting(realtime, context);
    } catch (error) {
      try {
        realtime?.close?.();
      } catch (_closeError) {
        // ignore cleanup errors
      }
      try {
        outputPacer?.close?.();
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

function buildOperatorCompletion({ call, dialResult, session, requestPayload, routeDecision, app, registry }) {
  return new Promise(resolve => {
    let completed = false;
    let connected = false;

    const finish = async (event, metadata = {}) => {
      if (completed) return;
      completed = true;
      clearTimer(timeout);
      await app.safeBridgeEvent(event, session, requestPayload, routeDecision, metadata);
      registry?.update?.(session.callRef, { state: terminalOperatorState(event), routeDecision });
      resolve();
    };

    const failOrFallback = async (event, reason) => {
      if (completed) return;
      completed = true;
      clearTimer(timeout);
      try {
        await app.handleOperatorFailure(call, session, requestPayload, routeDecision, reason, event);
      } finally {
        resolve();
      }
    };

    const sources = operatorEventSources(call, dialResult);
    if (sources.length === 0) {
      resolve();
      return;
    }

    for (const { source, leg } of sources) {
      for (const eventName of operatorAnswerEvents()) {
        registerOnce(source, eventName, () => {
          if (completed || connected) return;
          connected = true;
          clearTimer(timeout);
          void app.safeBridgeEvent('operator_answered', session, requestPayload, routeDecision, { provider_event: eventName });
          registry?.update?.(session.callRef, { state: 'operator_connected', routeDecision });
        });
      }
      for (const eventName of operatorNoAnswerEvents()) {
        registerOnce(source, eventName, () => { void failOrFallback('operator_no_answer', normalizeOperatorFailureReason(eventName)); });
      }
      for (const eventName of callErrorEvents()) {
        registerOnce(source, eventName, () => { void failOrFallback('operator_failed', normalizeOperatorFailureReason(eventName)); });
      }
      for (const eventName of callEndEvents()) {
        registerOnce(source, eventName, () => {
          if (connected) {
            void finish('session_completed', { provider_event: eventName, provider_leg: leg });
            return;
          }

          if (leg === 'operator') {
            void failOrFallback('operator_no_answer', normalizeOperatorFailureReason(eventName));
            return;
          }

          void finish('caller_hangup', { provider_event: eventName, provider_leg: leg });
        });
      }
    }

    const timeout = setTimer(() => {
      void failOrFallback('operator_no_answer', 'operator_timeout');
    }, operatorTimeoutMs(routeDecision));
  });
}

function operatorEventSources(call, dialResult) {
  return [
    { source: dialResult, leg: 'operator' },
    { source: call, leg: 'caller' },
    { source: call?.voice, leg: 'caller' }
  ].filter(({ source }) => source && (typeof source.on === 'function' || typeof source.once === 'function'));
}

function operatorAnswerEvents() {
  return ['answer', 'answered', 'connect', 'connected', 'accepted', 'ANSWER', 'ANSWERED', 'CONNECT', 'CONNECTED', 'ACCEPTED'];
}

function operatorNoAnswerEvents() {
  return ['no_answer', 'no-answer', 'noanswer', 'timeout', 'busy', 'rejected', 'declined', 'cancelled', 'canceled', 'NO_ANSWER', 'TIMEOUT', 'BUSY', 'REJECTED', 'DECLINED', 'CANCELLED'];
}

function operatorTimeoutMs(routeDecision = {}) {
  const raw = routeDecision.operator_timeout_ms || routeDecision.operatorTimeoutMs || routeDecision.timeout_ms || routeDecision.timeoutMs;
  const parsed = Number.parseInt(raw, 10);
  return Number.isFinite(parsed) && parsed > 0 ? parsed : 30_000;
}

function setTimer(handler, timeoutMs) {
  const timer = setTimeout(handler, timeoutMs);
  if (typeof timer.unref === 'function') timer.unref();
  return timer;
}

function clearTimer(timer) {
  if (timer) clearTimeout(timer);
}

function normalizeOperatorFailureReason(eventName) {
  return String(eventName || 'operator_failed').toLowerCase().replace(/[^a-z0-9]+/g, '_').replace(/^_+|_+$/g, '') || 'operator_failed';
}

function terminalOperatorState(event) {
  return event === 'session_completed' ? 'completed' : 'failed';
}

function operatorFallbackDecision(routeDecision = {}, reason = 'operator_failed') {
  const appRef = routeDecision.fallback_app_ref || routeDecision.fallbackAppRef;
  if (!appRef) return null;

  const fallbackMode = String(routeDecision.fallback_mode || routeDecision.fallbackMode || 'app').toLowerCase();
  if (!['app', 'ai'].includes(fallbackMode)) return null;

  return {
    ...routeDecision,
    action: fallbackMode === 'ai' ? 'ai' : 'app',
    app_ref: appRef,
    appRef,
    reason: `${reason}_fallback`
  };
}

function buildCompletion({ call, mediaStream, outputPacer, realtime, session, registry }) {
  return new Promise(resolve => {
    let completed = false;
    const finish = async action => {
      if (completed) return;
      completed = true;
      try {
        outputPacer?.close?.();
      } catch (_error) {
        // ignore pacer cleanup errors
      }
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
  const assistantName = String(context.captain?.name || context.ai?.name || '').trim();
  const pieces = [
    assistantName ? `Твое имя в Captain: ${assistantName}. Если пользователь спрашивает, как тебя зовут, отвечай этим именем. Для приветствий и вопросов о твоем имени не вызывай FAQ или другие инструменты.` : null,
    context.system_prompt,
    context.prompt,
    context.ai?.system_prompt || context.captain?.system_prompt,
    context.ai?.instructions,
    context.ai?.first_message ? `Начни разговор коротко: ${context.ai.first_message}` : null
  ].filter(Boolean);
  return pieces.join('\n\n');
}

function sendInitialGreeting(realtime, context = {}) {
  const greeting = initialGreetingText(context);
  if (!greeting || typeof realtime?.sendText !== 'function') return false;

  realtime.sendText(`Произнеси клиенту стартовую фразу дословно, без дополнительных комментариев: ${greeting}`);
  return true;
}

function initialGreetingText(context = {}) {
  return String(context.ai?.first_message || context.first_message || context.captain?.first_message || '').trim();
}

function normalizeContextTools(tools) {
  return (Array.isArray(tools) ? tools : [])
    .filter(tool => tool && tool.name && tool.enabled !== false)
    .map(tool => {
      const name = String(tool.name);
      return {
        name,
        description: tool.description || tool.summary || `OneLink tool ${name}`,
        parameters: normalizeToolParameters(name, tool.parameters || tool.schema)
      };
    });
}

function normalizeToolParameters(name, parameters) {
  const schema = isObjectSchema(parameters) ? parameters : { type: 'object', properties: {} };
  const properties = isObjectSchema(schema.properties) ? schema.properties : {};
  const hasProperties = Object.keys(properties).length > 0;
  const normalizedName = String(name || '').toLowerCase();

  if (normalizedName === 'faq_lookup' && !properties.query) {
    return {
      ...schema,
      type: 'object',
      properties: {
        ...properties,
        query: {
          type: 'string',
          description: 'The customer question or topic to search for in the FAQ database'
        }
      },
      required: mergeRequired(schema.required, ['query'])
    };
  }

  if (normalizedName === 'handoff' && !hasProperties) {
    return {
      ...schema,
      type: 'object',
      properties: {
        reason: {
          type: 'string',
          description: 'Short reason for handing the conversation to a human operator'
        },
        message: {
          type: 'string',
          description: 'Optional customer-facing transfer message'
        }
      }
    };
  }

  return { ...schema, type: 'object', properties };
}

function isObjectSchema(value) {
  return value && typeof value === 'object' && !Array.isArray(value);
}

function mergeRequired(existing, names) {
  return [...new Set([...(Array.isArray(existing) ? existing : []), ...names])];
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
  return `audio/pcm;rate=${FONOSTER_INPUT_RATE}`;
}

function fonosterAudioChunk(chunk, metadata = {}) {
  const buffer = Buffer.isBuffer(chunk) ? chunk : Buffer.from(chunk || []);
  if (buffer.length < 2) return Buffer.alloc(0);
  const sourceRate = audioRateFromMimeType(metadata.mimeType) || GEMINI_OUTPUT_RATE;
  return resamplePcm16(buffer, sourceRate, FONOSTER_CALL_RATE);
}

function audioRateFromMimeType(mimeType) {
  const match = String(mimeType || '').match(/rate\s*=\s*(\d+)/i);
  if (!match) return null;
  const rate = Number.parseInt(match[1], 10);
  return Number.isFinite(rate) && rate > 0 ? rate : null;
}

function parseStreamRate(value, fallback) {
  const rate = Number.parseInt(value, 10);
  return Number.isFinite(rate) && rate > 0 ? rate : fallback;
}

function shouldClearOutputOnInterrupt() {
  const value = String(process.env.VOICE_AGENT_CLEAR_AUDIO_ON_INTERRUPT || 'false').trim().toLowerCase();
  return ['1', 'true', 'yes', 'on'].includes(value);
}

function resamplePcm16(buffer, sourceRate, targetRate) {
  const evenLength = buffer.length - (buffer.length % 2);
  if (evenLength <= 0) return Buffer.alloc(0);
  const input = evenLength === buffer.length ? buffer : buffer.subarray(0, evenLength);
  if (!sourceRate || sourceRate === targetRate) return input;

  const inputSamples = Math.floor(input.length / 2);
  const outputSamples = Math.max(1, Math.floor((inputSamples * targetRate) / sourceRate));
  const output = Buffer.alloc(outputSamples * 2);

  for (let i = 0; i < outputSamples; i += 1) {
    const position = (i * sourceRate) / targetRate;
    const leftIndex = Math.min(Math.floor(position), inputSamples - 1);
    const rightIndex = Math.min(leftIndex + 1, inputSamples - 1);
    const fraction = position - leftIndex;
    const left = input.readInt16LE(leftIndex * 2);
    const right = input.readInt16LE(rightIndex * 2);
    output.writeInt16LE(clampPcm16(Math.round(left + ((right - left) * fraction))), i * 2);
  }

  return output;
}

function clampPcm16(value) {
  return Math.max(-32768, Math.min(32767, value));
}

class Pcm16FramePacer {
  constructor({ sampleRate, frameMs = 20, maxBufferedMs = 15_000, onFrame }) {
    this.sampleRate = Number(sampleRate) || 8_000;
    this.frameMs = Number(frameMs) || 20;
    this.frameBytes = Math.max(2, Math.round((this.sampleRate * this.frameMs * 2) / 1000));
    if (this.frameBytes % 2 !== 0) this.frameBytes += 1;
    this.maxBufferedBytes = Math.max(this.frameBytes, Math.round((this.sampleRate * 2 * maxBufferedMs) / 1000));
    this.onFrame = onFrame;
    this.buffer = Buffer.alloc(0);
    this.timer = null;
    this.closed = false;
  }

  push(chunk) {
    if (this.closed) return;
    const input = Buffer.isBuffer(chunk) ? chunk : Buffer.from(chunk || []);
    if (!input.length) return;

    this.buffer = this.buffer.length ? Buffer.concat([this.buffer, input]) : input;
    if (this.buffer.length > this.maxBufferedBytes) {
      const overflow = this.buffer.length - this.maxBufferedBytes;
      const alignedOverflow = overflow % 2 === 0 ? overflow : overflow + 1;
      this.buffer = this.buffer.subarray(Math.min(alignedOverflow, this.buffer.length));
    }
    this.start();
  }

  start() {
    if (this.timer || this.closed) return;
    this.timer = setInterval(() => this.tick(), this.frameMs);
    this.timer.unref?.();
    this.tick();
  }

  tick() {
    if (this.closed || this.buffer.length < this.frameBytes) return;
    const frame = this.buffer.subarray(0, this.frameBytes);
    this.buffer = this.buffer.subarray(this.frameBytes);
    this.onFrame?.(frame);
  }

  clear() {
    this.buffer = Buffer.alloc(0);
  }

  close() {
    this.closed = true;
    if (this.timer) {
      clearInterval(this.timer);
      this.timer = null;
    }
    this.clear();
  }
}

function compactPayload(payload = {}) {
  return Object.fromEntries(Object.entries(payload).filter(([, value]) => value !== undefined && value !== null && value !== ''));
}

function routePayload(requestPayload = {}, callRef) {
  return compactPayload({
    call_ref: callRef,
    ingress_number: requestPayload.ingress_number || requestPayload.ingressNumber || requestPayload.to_number || requestPayload.to,
    caller_number: requestPayload.caller_number || requestPayload.callerNumber || requestPayload.from_number || requestPayload.from,
    number_ref: requestPayload.number_ref || requestPayload.numberRef,
    account_id: requestPayload.account_id || requestPayload.accountId,
    app_ref: requestPayload.app_ref || requestPayload.appRef,
    media_session_ref: requestPayload.media_session_ref || requestPayload.mediaSessionRef
  });
}

function bridgeEventPayload(event, session, requestPayload = {}, routeDecision = {}, metadata = {}) {
  return compactPayload({
    event_key: `runtime:${session.callRef}:${event}`,
    event,
    call_ref: session.callRef,
    account_id: session.accountId || requestPayload.account_id || requestPayload.accountId,
    number_ref: session.numberRef || requestPayload.number_ref || requestPayload.numberRef,
    ingress_number: session.ingressNumber || requestPayload.ingress_number || requestPayload.ingressNumber || requestPayload.to,
    caller_number: session.callerNumber || requestPayload.caller_number || requestPayload.callerNumber || requestPayload.from,
    metadata: {
      ...metadata,
      route_action: routeDecision.action || routeDecision.mode,
      route_reason: routeDecision.reason
    }
  });
}

function applyRouteScope(session, routeDecision = {}) {
  if (!session || !routeDecision) return;
  session.accountId = routeDecision.account_id || routeDecision.accountId || session.accountId;
  session.numberRef = routeDecision.number_ref || routeDecision.numberRef || session.numberRef;
}

function shouldHandleAppRouteLocally(routeDecision = {}, _requestPayload = {}) {
  if (normalizeRouteAction(routeDecision) !== 'app') return false;
  return String(routeDecision.reason || '').toLowerCase() === 'recursive_runtime_app_ref';
}

function normalizeRouteAction(routeDecision = {}) {
  return String(routeDecision.action || routeDecision.mode || 'ai').trim().toLowerCase() || 'ai';
}

function routeLookupFailureDecision(error) {
  return {
    action: 'reject',
    reason: 'route_lookup_failed',
    message: sanitizeReason(error?.message || 'route lookup failed')
  };
}

function operatorTarget(routeDecision = {}) {
  return routeDecision.agent_aor || routeDecision.agentAor || routeDecision.destination || routeDecision.to || routeDecision.target;
}

async function dialOperator(call, routeDecision = {}) {
  const agentAor = operatorTarget(routeDecision);
  if (!agentAor) return false;

  const payload = { agent_aor: agentAor, destination: agentAor, to: agentAor };
  if (typeof call?.dial === 'function') return call.dial(payload);
  if (typeof call?.transfer === 'function') return call.transfer(payload);
  return false;
}

async function handoffToApp(call, routeDecision = {}) {
  const appRef = routeDecision.app_ref || routeDecision.appRef;
  if (!appRef) return false;

  const payload = { app_ref: appRef, appRef };
  if (typeof call?.transferToApp === 'function') return call.transferToApp(payload);
  if (typeof call?.transfer === 'function') return call.transfer(payload);
  return false;
}

async function rejectCall(call, routeDecision = {}) {
  const reason = routeDecision.reason || routeDecision.message || 'route_rejected';
  if (typeof call?.reject === 'function') return call.reject({ reason });
  if (typeof call?.hangup === 'function') return call.hangup({ reason });
  return false;
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
