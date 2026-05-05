const { VoiceSession } = require('../sessions/voice-session');
const { ScriptedFallbackResponder } = require('../realtime/scripted-fallback');

const streamConstants = loadStreamConstants();
const FONOSTER_INPUT_RATE = parseStreamRate(process.env.VOICE_AGENT_REALTIME_INPUT_RATE, 16_000);
const FONOSTER_CALL_RATE = parseStreamRate(process.env.VOICE_AGENT_REALTIME_CALL_RATE, 8_000);
const GEMINI_OUTPUT_RATE = parseStreamRate(process.env.VOICE_AGENT_REALTIME_OUTPUT_RATE, 24_000);

class VoiceApplication {
  constructor({
    client,
    registry = null,
    realtimeFactory = null,
    fallbackResponder = new ScriptedFallbackResponder(),
    mediaStreamFactory = null,
    toolTimeoutMs = 3_000,
    outputMaxBufferedMs = 1_500,
    clearOutputOnInterrupt = true
  } = {}) {
    if (!client) throw new Error('client is required');
    this.client = client;
    this.registry = registry;
    this.realtimeFactory = realtimeFactory;
    this.fallbackResponder = fallbackResponder;
    this.mediaStreamFactory = mediaStreamFactory;
    this.toolTimeoutMs = toolTimeoutMs;
    this.outputMaxBufferedMs = outputMaxBufferedMs;
    this.clearOutputOnInterrupt = clearOutputOnInterrupt;
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
    await session.safeEvent('call_started', {
      route_action: routeDecision.action || routeDecision.mode,
      route_reason: routeDecision.reason,
      app_ref: routeDecision.app_ref || routeDecision.appRef || requestPayload.app_ref || requestPayload.appRef,
      from: requestPayload.caller_number || requestPayload.from,
      to: requestPayload.ingress_number || requestPayload.to,
      direction: requestPayload.direction || 'inbound'
    });
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
      await session.safeEvent('error', { scope: 'gemini_live', error_code: 'realtime_unavailable', error_message: reason, retryable: false });
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
    await session.safeEvent('stream_started', {
      stream_ref: streamRef,
      media_session_ref: mediaSessionRef,
      direction: 'BOTH',
      input_rate: FONOSTER_INPUT_RATE,
      output_rate: FONOSTER_CALL_RATE,
      gemini_output_rate: GEMINI_OUTPUT_RATE,
      gemini_model: context.ai?.model
    });
    const outputPacer = mediaStream ? new Pcm16FramePacer({
      sampleRate: FONOSTER_CALL_RATE,
      frameMs: 20,
      maxBufferedMs: this.outputMaxBufferedMs,
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
      onToolCall: async callPayload => {
        const toolResult = await session.executeTool(callPayload.name, callPayload.args || {}, {
          provider: 'gemini-live',
          tool_call_id: callPayload.id
        });
        await this.handleRealtimeToolAction({ call, session, requestPayload, toolResult, toolCall: callPayload });
        return toolResult;
      },
      onInterrupt: async () => {
        if (this.clearOutputOnInterrupt) {
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

  async handleRealtimeToolAction({ call, session, requestPayload, toolResult, toolCall }) {
    const result = toolResult?.result;
    const action = String(result?.action || '').trim().toLowerCase();
    if (!toolResult?.ok || !action) return;

    if (action === 'transfer') {
      await this.handleRealtimeTransfer({ call, session, requestPayload, result, toolCall });
      return;
    }

    if (action === 'end_call') {
      const reason = result.reason || toolCall?.args?.reason || 'ai_voice_end_call';
      await session.safeEvent('call_ended', { ended_by: 'ai_agent', reason });
      if (typeof call?.hangup === 'function') {
        try {
          await call.hangup({ reason });
        } catch (_error) {
          // Provider hangup failure should not block final call state persistence.
        }
      }
      await session.close('session_completed', { reason });
    }
  }

  async handleRealtimeTransfer({ call, session, result, toolCall }) {
    const operatorAgentAor = result.operator_agent_aor || result.operatorAgentAor || result.agent_aor || result.agentAor;
    const reason = result.reason || toolCall?.args?.reason || 'voice_ai_requested_transfer';
    const dialStartedAt = new Date().toISOString();

    await session.safeEvent('transfer_requested', {
      requested_by: 'ai_tool',
      reason,
      operator_agent_aor: operatorAgentAor
    });
    await session.safeControl('transfer_started', { reason, operator_agent_aor: operatorAgentAor });

    let dialResult;
    try {
      dialResult = await dialOperator(call, { agent_aor: operatorAgentAor });
    } catch (error) {
      const errorMessage = sanitizeReason(error?.message || 'operator_dial_failed');
      await this.finalizeTransferFailure(session, {
        operatorAgentAor,
        reason: errorMessage,
        result: 'failed',
        dialStartedAt,
        errorCode: 'operator_dial_failed',
        errorMessage
      });
      return;
    }

    if (dialResult === false) {
      await this.finalizeTransferFailure(session, {
        operatorAgentAor,
        reason: 'operator_dial_unavailable',
        result: 'failed',
        dialStartedAt,
        errorCode: 'operator_dial_unavailable',
        errorMessage: 'operator dial is unavailable'
      });
      return;
    }

    this.trackRealtimeTransfer({ call, dialResult, session, operatorAgentAor, reason, dialStartedAt });
  }

  trackRealtimeTransfer({ call, dialResult, session, operatorAgentAor, reason, dialStartedAt }) {
    let settled = false;
    let connected = false;
    let answeredAt = null;

    const emitResult = async ({ result, errorCode = null, errorMessage = null }) => {
      const now = new Date().toISOString();
      const payload = {
        operator_agent_aor: operatorAgentAor,
        result,
        dial_started_at: dialStartedAt,
        answered_at: answeredAt,
        ended_at: connected ? null : now,
        duration_ms: Math.max(0, Date.now() - Date.parse(dialStartedAt)),
        error_code: errorCode,
        error_message: errorMessage
      };
      await session.safeEvent('transfer_result', payload);
      return payload;
    };

    const answer = async eventName => {
      if (settled || connected) return;
      connected = true;
      answeredAt = new Date().toISOString();
      session.transferState = { connected: true, operatorAgentAor, dialStartedAt, answeredAt };
      await session.safeControl('transfer_answered', { provider_event: eventName, operator_agent_aor: operatorAgentAor });
      await emitResult({ result: 'answered' });
    };

    const fail = async (result, eventName) => {
      if (settled) return;
      settled = true;
      const transferResult = await emitResult({
        result,
        errorCode: result,
        errorMessage: eventName
      });
      await session.safeControl('transfer_failed', { provider_event: eventName, operator_agent_aor: operatorAgentAor, result });
      await session.close('session_failed', {
        final_status: result === 'failed' ? 'failed' : 'operator_unavailable',
        reason: result,
        transfer_result: transferResult,
        error_code: result,
        error_message: eventName
      });
    };

    const complete = async eventName => {
      if (settled) return;
      settled = true;
      await session.safeControl('transfer_completed', { provider_event: eventName, operator_agent_aor: operatorAgentAor, reason });
      await session.safeEvent('call_ended', { ended_by: 'operator', reason: eventName });
      await session.close('transfer_completed', {
        final_status: connected ? 'transferred' : 'operator_unavailable',
        reason: connected ? 'operator_completed' : 'operator_unavailable',
        transfer_result: {
          operator_agent_aor: operatorAgentAor,
          result: connected ? 'answered' : 'no_answer',
          dial_started_at: dialStartedAt,
          answered_at: answeredAt,
          duration_ms: Math.max(0, Date.now() - Date.parse(dialStartedAt))
        }
      });
    };

    const sources = operatorEventSources(call, dialResult);
    for (const { source } of sources) {
      for (const eventName of operatorAnswerEvents()) registerOnce(source, eventName, () => { void answer(eventName); });
      for (const eventName of operatorNoAnswerEvents()) {
        registerOnce(source, eventName, () => { void fail(normalizeTransferResult(eventName), eventName); });
      }
      for (const eventName of callErrorEvents()) registerOnce(source, eventName, () => { void fail('failed', eventName); });
      for (const eventName of callEndEvents()) registerOnce(source, eventName, () => { void complete(eventName); });
    }

    if (sources.length === 0) {
      void session.safeEvent('transfer_result', {
        operator_agent_aor: operatorAgentAor,
        result: 'answered',
        dial_started_at: dialStartedAt,
        duration_ms: 0
      });
    }
  }

  async finalizeTransferFailure(session, { operatorAgentAor, reason, result, dialStartedAt, errorCode, errorMessage }) {
    const transferResult = {
      operator_agent_aor: operatorAgentAor,
      result,
      dial_started_at: dialStartedAt,
      ended_at: new Date().toISOString(),
      duration_ms: Math.max(0, Date.now() - Date.parse(dialStartedAt)),
      error_code: errorCode,
      error_message: errorMessage
    };
    await session.safeEvent('transfer_result', transferResult);
    await session.safeEvent('error', { scope: 'transfer', error_code: errorCode, error_message: errorMessage, retryable: false });
    await session.safeControl('transfer_failed', { reason, operator_agent_aor: operatorAgentAor, result });
    await session.close('session_failed', {
      final_status: result === 'failed' ? 'failed' : 'operator_unavailable',
      reason,
      transfer_result: transferResult,
      error_code: errorCode,
      error_message: errorMessage
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
    let answeredOperatorSource = null;
    let timeout;

    const sources = operatorEventSources(call, dialResult);
    const operatorSources = sources.filter(({ leg }) => leg === 'operator');
    const failedOperatorSources = new Set();

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

    const markOperatorFailed = (source, event, reason) => {
      if (completed || connected) return;
      failedOperatorSources.add(source);
      if (failedOperatorSources.size >= operatorSources.length) {
        void failOrFallback(event, reason);
      }
    };

    const markOperatorAnswered = (source, eventName, candidate) => {
      if (completed || connected) return;
      connected = true;
      answeredOperatorSource = source;
      clearTimer(timeout);
      cleanupLosingOperatorLegs(operatorSources, source);
      void app.safeBridgeEvent(
        'operator_answered',
        session,
        requestPayload,
        routeDecision,
        operatorCandidateMetadata(candidate, { provider_event: eventName })
      );
      registry?.update?.(session.callRef, { state: 'operator_connected', routeDecision });
    };

    if (sources.length === 0) {
      resolve();
      return;
    }

    for (const { source, leg, candidate } of sources) {
      for (const eventName of operatorAnswerEvents()) {
        registerOnce(source, eventName, () => {
          if (leg === 'operator') {
            markOperatorAnswered(source, eventName, candidate);
          }
        });
      }
      for (const eventName of operatorNoAnswerEvents()) {
        registerOnce(source, eventName, () => {
          if (leg === 'operator') {
            markOperatorFailed(source, 'operator_no_answer', normalizeOperatorFailureReason(eventName));
          }
        });
      }
      for (const eventName of callErrorEvents()) {
        registerOnce(source, eventName, () => {
          if (leg === 'operator') {
            markOperatorFailed(source, 'operator_failed', normalizeOperatorFailureReason(eventName));
            return;
          }

          void failOrFallback('operator_failed', normalizeOperatorFailureReason(eventName));
        });
      }
      for (const eventName of callEndEvents()) {
        registerOnce(source, eventName, () => {
          if (connected) {
            if (leg === 'operator' && source !== answeredOperatorSource) return;

            void finish('session_completed', { provider_event: eventName, provider_leg: leg });
            return;
          }

          if (leg === 'operator') {
            markOperatorFailed(source, 'operator_no_answer', normalizeOperatorFailureReason(eventName));
            return;
          }

          void finish('caller_hangup', { provider_event: eventName, provider_leg: leg });
        });
      }
    }

    timeout = setTimer(() => {
      void failOrFallback('operator_no_answer', 'operator_timeout');
    }, operatorTimeoutMs(routeDecision));
  });
}

function operatorEventSources(call, dialResult) {
  return [
    ...operatorDialResults(dialResult).map(({ source, candidate }) => ({ source, leg: 'operator', candidate })),
    { source: call, leg: 'caller' },
    { source: call?.voice, leg: 'caller' }
  ].filter(({ source }) => source && (typeof source.on === 'function' || typeof source.once === 'function'));
}

function operatorDialResults(dialResult) {
  return (Array.isArray(dialResult) ? dialResult : [dialResult]).filter(Boolean).map(entry => {
    if (entry?.source) return { source: entry.source, candidate: entry.candidate || entry.__operatorCandidate };
    return { source: entry, candidate: entry?.__operatorCandidate };
  });
}

function operatorCandidateMetadata(candidate = {}, metadata = {}) {
  return compactPayload({
    ...metadata,
    id: candidate.id,
    agent_ref: candidate.agent_ref,
    agentRef: candidate.agent_ref,
    agent_aor: candidate.agent_aor,
    operator_agent_aor: candidate.agent_aor,
    user_id: candidate.user_id,
    userId: candidate.user_id,
    chatwoot_user_id: candidate.user_id
  });
}

function cleanupLosingOperatorLegs(operatorSources, answeredSource) {
  for (const { source } of operatorSources) {
    if (!source || source === answeredSource) continue;
    try {
      if (typeof source.hangup === 'function') source.hangup({ reason: 'answered_by_other_operator' });
      else if (typeof source.reject === 'function') source.reject({ reason: 'answered_by_other_operator' });
      else if (typeof source.close === 'function') source.close();
    } catch (_error) {
      // Losing operator leg cleanup is best effort; the answered leg owns the call.
    }
  }
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

function normalizeTransferResult(eventName) {
  const normalized = normalizeOperatorFailureReason(eventName);
  if (normalized.includes('busy')) return 'busy';
  if (normalized.includes('cancel')) return 'cancelled';
  if (normalized.includes('reject') || normalized.includes('decline')) return 'cancelled';
  if (normalized.includes('no_answer') || normalized.includes('timeout') || normalized.includes('end')) return 'no_answer';
  return 'failed';
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
        await session.safeEvent('call_ended', { reason: action || 'session_completed' });
      } catch (_error) {
        // event persistence errors should not block media cleanup
      }
      try {
        await session.close(completionAction(session, action), completionMetadata(session, action));
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

function completionAction(session, action) {
  if (session?.transferState?.connected && action === 'session_completed') return 'transfer_completed';
  return action || 'session_completed';
}

function completionMetadata(session, action) {
  if (!session?.transferState?.connected || action !== 'session_completed') return {};

  return {
    final_status: 'transferred',
    reason: 'operator_completed',
    transfer_result: {
      operator_agent_aor: session.transferState.operatorAgentAor,
      result: 'answered',
      dial_started_at: session.transferState.dialStartedAt,
      answered_at: session.transferState.answeredAt,
      duration_ms: Math.max(0, Date.now() - Date.parse(session.transferState.dialStartedAt))
    }
  };
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
      ...operatorRouteMetadata(routeDecision),
      ...metadata,
      route_action: routeDecision.action || routeDecision.mode,
      route_reason: routeDecision.reason
    }
  });
}

function operatorRouteMetadata(routeDecision = {}) {
  const candidates = operatorTargetCandidates(routeDecision);
  if (candidates.length === 0) return {};

  return compactPayload({
    operator_pool: routeDecision.operator_pool || routeDecision.operatorPool || candidates.length > 1,
    operator_pool_size: routeDecision.operator_pool_size || routeDecision.operatorPoolSize || candidates.length,
    operator_candidates: candidates,
    operator_candidate_binding_ids: candidates.map(candidate => candidate.id).filter(Boolean),
    operator_candidate_user_ids: candidates.map(candidate => candidate.user_id).filter(Boolean),
    operator_candidate_agent_refs: candidates.map(candidate => candidate.agent_ref).filter(Boolean),
    operator_candidate_agent_aors: candidates.map(candidate => candidate.agent_aor).filter(Boolean)
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

function operatorTargetCandidates(routeDecision = {}) {
  const candidates = [];
  const configuredCandidates = routeDecision.operator_candidates || routeDecision.operatorCandidates || [];
  for (const candidate of Array.isArray(configuredCandidates) ? configuredCandidates : []) {
    addOperatorCandidate(candidates, {
      agent_ref: candidate.agent_ref || candidate.agentRef,
      agent_aor: candidate.agent_aor || candidate.agentAor || candidate.destination || candidate.to || candidate.target,
      id: candidate.id || candidate.agent_binding_id || candidate.agentBindingId,
      user_id: candidate.user_id || candidate.userId,
      name: candidate.name
    });
  }

  const configuredAors = routeDecision.agent_aors || routeDecision.agentAors || routeDecision.operator_agent_aors || routeDecision.operatorAgentAors;
  for (const agentAor of Array.isArray(configuredAors) ? configuredAors : []) {
    addOperatorCandidate(candidates, { agent_aor: agentAor });
  }

  addOperatorCandidate(candidates, {
    agent_ref: routeDecision.agent_ref || routeDecision.agentRef,
    agent_aor: routeDecision.agent_aor || routeDecision.agentAor || routeDecision.destination || routeDecision.to || routeDecision.target,
    id: routeDecision.id || routeDecision.agent_binding_id || routeDecision.agentBindingId,
    user_id: routeDecision.user_id || routeDecision.userId
  });

  return candidates;
}

function addOperatorCandidate(candidates, candidate = {}) {
  const agentAor = candidate.agent_aor || candidate.agentAor;
  if (!agentAor || candidates.some(existing => existing.agent_aor === agentAor)) return;

  candidates.push(compactPayload({
    id: candidate.id || candidate.agent_binding_id || candidate.agentBindingId,
    agent_ref: candidate.agent_ref || candidate.agentRef,
    agent_aor: agentAor,
    user_id: candidate.user_id || candidate.userId,
    name: candidate.name
  }));
}

async function dialOperator(call, routeDecision = {}) {
  const candidates = operatorTargetCandidates(routeDecision);
  if (candidates.length === 0) return false;

  const dialResults = await Promise.all(candidates.map(async candidate => {
    try {
      return await dialOperatorCandidate(call, candidate);
    } catch (_error) {
      return false;
    }
  }));
  const successfulResults = dialResults.filter(Boolean);
  if (successfulResults.length === 0) return false;
  if (successfulResults.length === 1) return successfulResults[0];

  return successfulResults;
}

async function dialOperatorCandidate(call, candidate) {
  const payload = {
    agent_aor: candidate.agent_aor,
    destination: candidate.agent_aor,
    to: candidate.agent_aor,
    agent_ref: candidate.agent_ref,
    user_id: candidate.user_id
  };

  let result = false;
  if (typeof call?.dial === 'function') result = await call.dial(payload);
  else if (typeof call?.transfer === 'function') result = await call.transfer(payload);

  if (result === false) return false;
  return attachOperatorCandidate(result, candidate);
}

function attachOperatorCandidate(result, candidate) {
  if (result && typeof result === 'object') {
    try {
      result.__operatorCandidate = candidate;
      return result;
    } catch (_error) {
      // Some provider SDK objects may be sealed; fall back to a wrapper.
      return { source: result, candidate };
    }
  }

  // Some provider adapters resolve dial()/transfer() with no leg object on success.
  return { source: result, candidate };
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
