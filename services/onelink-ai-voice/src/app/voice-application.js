const { VoiceSession } = require('../sessions/voice-session');
const { ScriptedFallbackResponder } = require('../realtime/scripted-fallback');
const { startManagedVoiceStream } = require('../fonoster/managed-stream');
const { RecordingWriter } = require('../recordings/recording-writer');
const { DialogueDirector } = require('../dialogue/dialogue-director');

const streamConstants = loadStreamConstants();
const FONOSTER_INPUT_RATE = parseStreamRate(process.env.VOICE_AGENT_REALTIME_INPUT_RATE, 16_000);
const FONOSTER_CALL_RATE = parseStreamRate(process.env.VOICE_AGENT_REALTIME_CALL_RATE, 8_000);
const GEMINI_OUTPUT_RATE = parseStreamRate(process.env.VOICE_AGENT_REALTIME_OUTPUT_RATE, 24_000);
const RECORDING_SAMPLE_RATE = parseStreamRate(process.env.VOICE_AGENT_RECORDING_SAMPLE_RATE, 16_000);

class VoiceApplication {
  constructor({
    client,
    registry = null,
    realtimeFactory = null,
    fallbackResponder = new ScriptedFallbackResponder(),
    mediaStreamFactory = null,
    managedStreamStarter = startManagedVoiceStream,
    recordingWriterFactory = null,
    recordingEnabled = envFlag('VOICE_AGENT_RECORDING_ENABLED'),
    toolTimeoutMs = 3_000,
    outputMaxBufferedMs = 5_000,
    clearOutputOnInterrupt = false,
    postToolContinuationMs = 4_000,
    businessFaqGateDelayMs = 650,
    ordinaryAnswerContinuationMs = 2_500,
    incompleteAnswerContinuationMs = 1_200,
    initialMediaKeepaliveMs = parsePositiveInt(process.env.VOICE_AGENT_INITIAL_MEDIA_KEEPALIVE_MS, 0),
    answerTimeoutMs = parsePositiveInt(process.env.VOICE_AGENT_ANSWER_TIMEOUT_MS, 5_000)
  } = {}) {
    if (!client) throw new Error('client is required');
    this.client = client;
    this.registry = registry;
    this.realtimeFactory = realtimeFactory;
    this.fallbackResponder = fallbackResponder;
    this.mediaStreamFactory = mediaStreamFactory;
    this.managedStreamStarter = managedStreamStarter;
    this.recordingWriterFactory = recordingWriterFactory;
    this.recordingEnabled = recordingEnabled;
    this.toolTimeoutMs = toolTimeoutMs;
    this.outputMaxBufferedMs = outputMaxBufferedMs;
    this.clearOutputOnInterrupt = clearOutputOnInterrupt;
    this.postToolContinuationMs = postToolContinuationMs;
    this.businessFaqGateDelayMs = businessFaqGateDelayMs;
    this.ordinaryAnswerContinuationMs = ordinaryAnswerContinuationMs;
    this.incompleteAnswerContinuationMs = incompleteAnswerContinuationMs;
    this.initialMediaKeepaliveMs = initialMediaKeepaliveMs;
    this.answerTimeoutMs = answerTimeoutMs;
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
      bridgeCallRef: bridgeCallRefCandidate(requestPayload),
      toolTimeoutMs: this.toolTimeoutMs
    });
    this.registry?.create({
      ...requestPayload,
      callRef,
      context: {},
      accountId: requestPayload.account_id
    });

    const routeDecision = await this.routeInboundSafely(requestPayload, callRef);
    applyRouteScope(session, routeDecision);
    this.registry?.update?.(callRef, { routeDecision, accountId: session.accountId, state: 'received' });
    void session.safeEvent('app_received_call', correlationPayload(session, requestPayload, routeDecision));
    await this.safeBridgeEvent('session_started', session, requestPayload, routeDecision);
    await session.safeEvent('call_started', {
      route_action: routeDecision.action || routeDecision.mode,
      route_reason: routeDecision.reason,
      app_ref: selectedAppRef(requestPayload, routeDecision),
      route_app_ref: routeAppRef(routeDecision),
      topology: directAiTopology(requestPayload, routeDecision),
      from: requestPayload.caller_number || requestPayload.from,
      to: requestPayload.ingress_number || requestPayload.to,
      direction: requestPayload.direction || 'inbound'
    });
    const routeAction = normalizeRouteAction(routeDecision);
    const handleLocallyAsAi = shouldHandleAppRouteLocally(routeDecision, requestPayload);

    if (routeAction === 'operator') {
      const answerFailure = await this.answerCallOrFail({ call, session, requestPayload, routeDecision });
      if (answerFailure) return answerFailure;
      void session.safeEvent('app_answered', correlationPayload(session, requestPayload, routeDecision));
      await this.safeBridgeEvent('operator_ringing', session, requestPayload, routeDecision);
      const passiveRecording = await this.startPassiveRecording(call, session, requestPayload, routeDecision);
      try {
        const dialResult = await dialOperator(call, routeDecision);
        if (dialResult === false) {
          await closePassiveRecording(passiveRecording);
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
          registry: this.registry,
          passiveRecording
        });
        return { session, decision: routeDecision, mode: 'operator', completion };
      } catch (error) {
        await closePassiveRecording(passiveRecording);
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
      const answerFailure = await this.answerCallOrFail({ call, session, requestPayload, routeDecision });
      if (answerFailure) return answerFailure;
      void session.safeEvent('app_answered', correlationPayload(session, requestPayload, routeDecision));
      await this.safeBridgeEvent('app_routing', session, requestPayload, routeDecision);
      const passiveRecording = await this.startPassiveRecording(call, session, requestPayload, routeDecision);
      try {
        await handoffToApp(call, routeDecision);
        this.registry?.update?.(callRef, { routeDecision, state: 'app' });
        const completion = passiveRecording ? buildPassiveRecordingCompletion({ call, passiveRecording }) : Promise.resolve();
        return { session, decision: routeDecision, mode: 'app', completion };
      } catch (error) {
        await closePassiveRecording(passiveRecording);
        const reason = sanitizeReason(error?.message || 'app_handoff_failed');
        await this.safeBridgeEvent('session_failed', session, requestPayload, routeDecision, { reason, original_reason: 'app_handoff_failed' });
        await hangupSafely(call, reason);
        this.registry?.update?.(callRef, { routeDecision, state: 'failed' });
        return { session, decision: routeDecision, mode: 'app_failed', completion: Promise.resolve(), reason };
      }
    }

    const answerFailure = await this.answerCallOrFail({ call, session, requestPayload, routeDecision });
    if (answerFailure) return answerFailure;
    void session.safeEvent('app_answered', correlationPayload(session, requestPayload, routeDecision));

    let mediaStream;
    let initialMediaKeepalive = null;
    try {
      const mediaStreamRequestedAt = Date.now();
      mediaStream = await this.startMediaStream(call, { session, requestPayload, routeDecision });
      if (!mediaStream) throw mediaStreamEstablishmentError('call.stream returned no media stream', 'call.stream');
      const mediaStreamEstablishedAt = Date.now();
      mediaStream.__onelinkEstablishedAt = new Date(mediaStreamEstablishedAt).toISOString();
      mediaStream.__onelinkEstablishmentMs = Math.max(0, mediaStreamEstablishedAt - mediaStreamRequestedAt);
      await session.safeEvent('media_stream_established', {
        ...correlationPayload(session, requestPayload, routeDecision),
        stream_ref: mediaStream.streamRef || mediaStream.stream_ref || requestPayload.stream_ref || requestPayload.streamRef,
        media_session_ref: mediaStream.mediaSessionRef || mediaStream.media_session_ref || requestPayload.media_session_ref || requestPayload.mediaSessionRef || call?.request?.mediaSessionRef || session.callRef,
        media_stream_requested_at: new Date(mediaStreamRequestedAt).toISOString(),
        media_stream_established_at: mediaStream.__onelinkEstablishedAt,
        media_stream_establishment_ms: mediaStream.__onelinkEstablishmentMs
      });
      initialMediaKeepalive = startInitialMediaKeepalive({
        mediaStream,
        session,
        requestPayload,
        durationMs: this.initialMediaKeepaliveMs
      });
    } catch (error) {
      return this.handleMediaStreamEstablishmentFailure({
        error,
        call,
        session,
        requestPayload,
        routeDecision,
        context: routeDecision
      });
    }

    const context = await session.bootstrap();
    this.registry?.update?.(callRef, { context, state: session.state });

    if (session.state === 'fallback') {
      initialMediaKeepalive?.stop?.('fallback');
      closeMediaStreamSafely(mediaStream);
      this.registry?.close?.(callRef, context?.ai?.reason || 'context_unavailable');
      await this.fallbackResponder.greet(call);
      return { session, context, mode: 'fallback', completion: Promise.resolve() };
    }

    let bridge;
    try {
      bridge = await this.startRealtimeBridge(call, session, context, requestPayload, mediaStream, initialMediaKeepalive);
      this.registry?.update?.(callRef, {
        stream_ref: session.streamRef,
        media_session_ref: session.mediaSessionRef,
        state: session.state || 'active'
      });
    } catch (error) {
      initialMediaKeepalive?.stop?.('realtime_unavailable');
      const reason = sanitizeReason(error?.reason || error?.message || 'realtime_unavailable');
      if (isMediaStreamEstablishmentError(error)) {
        return this.handleMediaStreamEstablishmentFailure({
          error,
          call,
          session,
          requestPayload,
          routeDecision,
          context
        });
      }
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

    return providedRouteDecision(requestPayload) || this.client.routeInbound(routePayload(requestPayload, callRef));
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

  async startRealtimeBridge(call, session, context, requestPayload = {}, existingMediaStream = null, initialMediaKeepalive = null) {
    const mediaStream = existingMediaStream || await this.startMediaStream(call, { session, requestPayload, routeDecision: context });
    if (!mediaStream) throw mediaStreamEstablishmentError('call.stream returned no media stream', 'call.stream');

    let streamRef = String(mediaStream?.streamRef || mediaStream?.stream_ref || requestPayload.stream_ref || requestPayload.streamRef || '').trim();
    const mediaSessionRef = String(mediaStream?.mediaSessionRef || mediaStream?.media_session_ref || requestPayload.media_session_ref || requestPayload.mediaSessionRef || call?.request?.mediaSessionRef || session.callRef || '').trim();
    if (!streamRef) {
      closeMediaStreamSafely(mediaStream);
      const error = mediaStreamEstablishmentError('media_stream_missing_stream_ref', 'call.stream');
      error.upstreamReason = 'media_stream_missing_stream_ref';
      throw error;
    }
    session.streamRef = streamRef || session.streamRef;
    session.mediaSessionRef = mediaSessionRef || session.mediaSessionRef;
    initialMediaKeepalive?.updateRefs?.({ streamRef, mediaSessionRef });
    let acceptingInput = true;
    let lastAudioOutLogAt = 0;
    let lastToolWaitFillerTranscriptAt = 0;
    let lastCallerTranscriptAt = null;
    let lastConfirmedCallerInterruptAt = null;
    let lastCallerAudioAt = null;
    let lastAiTranscriptAt = null;
    let lastAiAudioAt = null;
    let aiOutputActiveUntilMs = 0;
    let lastMediaWriteAt = null;
    const clearOutputOnInterrupt = context.ai?.clear_audio_on_interrupt ?? context.ai?.clearAudioOnInterrupt ?? this.clearOutputOnInterrupt;
    const postToolWatchdog = createPostToolWatchdog({
      timeoutMs: context.ai?.post_tool_continuation_ms ?? context.ai?.postToolContinuationMs ?? this.postToolContinuationMs,
      session,
      requestPayload,
      context,
      sendContinuation: text => realtime?.sendText?.(text)
    });
    const ordinaryAnswerWatchdog = createOrdinaryAnswerWatchdog({
      timeoutMs: context.ai?.ordinary_answer_continuation_ms ?? context.ai?.ordinaryAnswerContinuationMs ?? this.ordinaryAnswerContinuationMs,
      session,
      requestPayload,
      context,
      sendContinuation: text => realtime?.sendText?.(text)
    });
    const incompleteAnswerWatchdog = createIncompleteAnswerWatchdog({
      timeoutMs: context.ai?.incomplete_answer_continuation_ms ?? context.ai?.incompleteAnswerContinuationMs ?? this.incompleteAnswerContinuationMs,
      session,
      requestPayload,
      context,
      sendContinuation: text => realtime?.sendText?.(text)
    });
    const businessFaqGate = createBusinessFaqGate({
      delayMs: context.ai?.business_faq_gate_after_ms ?? context.ai?.businessFaqGateAfterMs ?? this.businessFaqGateDelayMs,
      session,
      requestPayload,
      context,
      executeTool: (name, args, metadata) => session.executeTool(name, args, metadata),
      foregroundTimeoutMs: toolName => foregroundToolWaitMs(context, toolName),
      sendContinuation: text => realtime?.sendText?.(text)
    });
    const mediaFrameBytes = pcm16FrameBytes(FONOSTER_CALL_RATE, 20);
    const recordingWriter = this.createRecordingWriter(session, requestPayload, context);
    const degradedRecordingDirections = new Set();
    const writeRecordingAudio = (direction, data, metadata = {}) => {
      if (!recordingWriter || !data) return;
      const missingDirection = direction === 'inbound' ? 'caller' : 'remote';
      const reportDegraded = error => {
        if (degradedRecordingDirections.has(direction)) return;
        degradedRecordingDirections.add(direction);
        void session.safeEvent('recording_incomplete', {
          recording_status: 'incomplete',
          degraded: true,
          missing_direction: missingDirection,
          reason: 'recording_write_failed',
          error_message: sanitizeReason(error?.message || error?.reason || 'recording_write_failed'),
          stream_ref: metadata.stream_ref || streamRef,
          media_session_ref: metadata.media_session_ref || mediaSessionRef
        });
      };
      try {
        const result = direction === 'inbound'
          ? recordingWriter.writeInbound(data, metadata)
          : recordingWriter.writeOutbound(data, metadata);
        if (result && typeof result.then === 'function') result.catch(reportDegraded);
      } catch (error) {
        reportDegraded(error);
      }
    };
    if (recordingWriter) {
      void recordingWriter.start({ sampleRate: RECORDING_SAMPLE_RATE });
    }
    await session.safeEvent('stream_started', {
      stream_ref: streamRef,
      media_session_ref: mediaSessionRef,
      direction: streamConstants.bothDirection,
      input_rate: FONOSTER_INPUT_RATE,
      output_rate: FONOSTER_CALL_RATE,
      gemini_output_rate: GEMINI_OUTPUT_RATE,
      recording_sample_rate: RECORDING_SAMPLE_RATE,
      gemini_model: context.ai?.model,
      output_format: streamConstants.wavFormat,
      output_encoding: 'pcm_s16le',
      frame_ms: 20,
      expected_frame_bytes: mediaFrameBytes
    });
    const establishedAtMs = Date.parse(mediaStream.__onelinkEstablishedAt || '');
    await session.safeEvent('media_stream_started', {
      ...correlationPayload(session, requestPayload, context),
      stream_ref: streamRef,
      media_stream_id: streamRef,
      media_session_ref: mediaSessionRef,
      media_stream_established_at: mediaStream.__onelinkEstablishedAt,
      media_stream_establishment_ms: mediaStream.__onelinkEstablishmentMs,
      established_to_media_started_ms: Number.isNaN(establishedAtMs) ? undefined : Math.max(0, Date.now() - establishedAtMs),
      input_rate: FONOSTER_INPUT_RATE,
      telephony_output_rate: FONOSTER_CALL_RATE,
      gemini_output_rate: GEMINI_OUTPUT_RATE,
      recording_sample_rate: RECORDING_SAMPLE_RATE,
      output_format: streamConstants.wavFormat,
      output_encoding: 'pcm_s16le',
      frame_ms: 20,
      expected_frame_bytes: mediaFrameBytes,
      output_max_buffered_ms: this.outputMaxBufferedMs
    });
    let mediaWriterStarted = false;
    let mediaWriteFailed = false;
    const failMediaWrite = (reason, metadata = {}) => {
      if (mediaWriteFailed) return;
      mediaWriteFailed = true;
      const payload = compactPayload({
        reason,
        output_format: streamConstants.wavFormat,
        output_encoding: 'pcm_s16le',
        telephony_output_rate: FONOSTER_CALL_RATE,
        frame_ms: 20,
        expected_frame_bytes: mediaFrameBytes,
        stream_ref: streamRef,
        media_session_ref: mediaSessionRef,
        ...metadata
      });
      void session.safeEvent('media_stream_framing_error', payload);
      void completion?.finish?.('media_stream_framing_error', payload);
    };
    const outputPacer = mediaStream ? new Pcm16FramePacer({
      sampleRate: FONOSTER_CALL_RATE,
      frameMs: 20,
      maxBufferedMs: this.outputMaxBufferedMs,
      onDrop: payload => {
        void session.safeEvent('pacer_drop', {
          ...payload,
          stream_ref: streamRef,
          media_session_ref: mediaSessionRef
        });
      },
      onFrame: data => {
        const frame = Buffer.from(data);
        const validationError = validatePcm16Frame(frame, mediaFrameBytes);
        if (validationError) {
          failMediaWrite(validationError, { actual_frame_bytes: frame.length });
          return;
        }
        if (!mediaWriterStarted) {
          mediaWriterStarted = true;
          void session.safeEvent('media_writer_started', {
            stream_ref: streamRef,
            media_session_ref: mediaSessionRef,
            output_format: streamConstants.wavFormat,
            output_encoding: 'pcm_s16le',
            telephony_output_rate: FONOSTER_CALL_RATE,
            frame_ms: 20,
            frame_bytes: frame.length
          });
        }
        try {
          const markMediaWrite = () => {
            lastMediaWriteAt = new Date().toISOString();
          };
          const writeResult = mediaStream.write({
            mediaSessionRef,
            streamRef,
            format: streamConstants.wavFormat,
            type: streamConstants.audioOut,
            kind: 'model_audio',
            data: frame
          });
          if (writeResult && typeof writeResult.then === 'function') {
            writeResult
              .then(markMediaWrite)
              .catch(error => {
                const reason = mediaWriteFailureReason(error, 'media_writer_rejected');
                failMediaWrite(reason, {
                  error_message: sanitizeReason(error?.message || error?.reason || reason)
                });
              });
          } else {
            markMediaWrite();
          }
        } catch (error) {
          const reason = mediaWriteFailureReason(error, 'media_writer_failed');
          failMediaWrite(reason, {
            error_message: sanitizeReason(error?.message || error?.reason || reason)
          });
        }
      }
    }) : null;
    let completion = null;
    let dialogueDirector = null;

    const confirmCallerTranscriptInterrupt = async (item = {}) => {
      if (item.final === false) return;
      if (!shouldClearOutputBufferOnCallerTranscript(clearOutputOnInterrupt, {
        callerTranscript: item.text,
        lastCallerTranscriptAt,
        lastAiAudioAt,
        aiOutputActiveUntilMs,
        lastConfirmedCallerInterruptAt
      })) return;

      lastConfirmedCallerInterruptAt = lastCallerTranscriptAt;
      aiOutputActiveUntilMs = 0;
      outputPacer?.clear?.();
      realtime?.interrupt?.();
      await session.safeControl('caller_interrupted', compactPayload({
        provider: item.provider || 'gemini-live',
        reason: 'caller_transcript_confirmed',
        source: 'caller_transcript_confirmed',
        clear_output_buffer: true,
        caller_transcript: sanitizedInterruptTranscript(item.text),
        last_caller_transcript_at: lastCallerTranscriptAt,
        last_caller_audio_at: lastCallerAudioAt,
        last_ai_transcript_at: lastAiTranscriptAt,
        last_ai_audio_at: lastAiAudioAt,
        stream_ref: streamRef,
        media_session_ref: mediaSessionRef
      }));
    };

    const callbacks = {
      systemPrompt: buildSystemPrompt(context),
      tools: normalizeContextTools(context.tools),
      onAudio: (chunk, metadata = {}) => {
        initialMediaKeepalive?.stop?.('model_audio');
        if (!outputPacer || !chunk) return;
        const data = fonosterAudioChunk(chunk, metadata);
        if (!data.length) return;
        const now = Date.now();
        lastAiAudioAt = new Date(now).toISOString();
        aiOutputActiveUntilMs = Math.max(aiOutputActiveUntilMs, now + outputPlaybackDurationMs(outputPacer, data));
        if (!recentToolWaitFillerTranscript(now, lastToolWaitFillerTranscriptAt)) {
          postToolWatchdog.cancel('model_audio');
        }
        ordinaryAnswerWatchdog.cancel('model_audio');
        incompleteAnswerWatchdog.cancel('model_audio');
        if (now - lastAudioOutLogAt >= 1_000) {
          lastAudioOutLogAt = now;
          void session.safeEvent('realtime_audio_out', {
            provider: metadata.provider || 'gemini-live',
            bytes: data.length,
            mime_type: metadata.mimeType
          });
        }
        const sourceRate = audioRateFromMimeType(metadata.mimeType) || GEMINI_OUTPUT_RATE;
        const recordingOutput = resamplePcm16(Buffer.from(chunk), sourceRate, RECORDING_SAMPLE_RATE);
        writeRecordingAudio('outbound', recordingOutput, {
          stream_ref: streamRef,
          media_session_ref: mediaSessionRef,
          source: 'realtime_model_audio',
          source_rate: sourceRate,
          recording_sample_rate: RECORDING_SAMPLE_RATE
        });
        outputPacer.push(data);
      },
      onTranscript: item => {
        const speaker = normalizeSpeaker(item.speaker);
        if (speaker === 'caller') {
          lastCallerTranscriptAt = item.at || new Date().toISOString();
          void confirmCallerTranscriptInterrupt(item);
          session.recordCallerTranscript(item.text, { final: item.final !== false, provider: item.provider, at: item.at });
          incompleteAnswerWatchdog.cancel('caller_transcript');
          if (item.final !== false) {
            ordinaryAnswerWatchdog.arm(item);
            businessFaqGate.consider(item);
          }
        } else {
          lastAiTranscriptAt = item.at || new Date().toISOString();
          if (isToolWaitFillerTranscript(item.text, context.ai)) {
            lastToolWaitFillerTranscriptAt = Date.now();
          } else if (String(item.text || '').trim()) {
            postToolWatchdog.cancel('model_transcript');
            ordinaryAnswerWatchdog.cancel('model_transcript');
            if (item.final !== false && isLikelyIncompleteAnswer(item.text)) {
              incompleteAnswerWatchdog.arm(item);
            } else {
              incompleteAnswerWatchdog.cancel('model_transcript');
            }
          }
          session.recordAiTranscript(item.text, { final: item.final !== false, provider: item.provider, at: item.at });
        }
      },
      onToolCall: async callPayload => {
        ordinaryAnswerWatchdog.cancel('model_tool_call');
        incompleteAnswerWatchdog.cancel('model_tool_call');
        const gatedToolResult = businessFaqGate.consumeToolCall(callPayload);
        if (!gatedToolResult) businessFaqGate.cancel('model_tool_call');
        dialogueDirector?.startToolWait(callPayload);
        const toolResult = gatedToolResult ? await gatedToolResult : await session.executeTool(callPayload.name, callPayload.args || {}, {
          provider: 'gemini-live',
          tool_call_id: callPayload.id,
          foreground_timeout_ms: foregroundToolWaitMs(context, callPayload.name),
          onAsyncResult: async lateResult => {
            dialogueDirector?.finishToolWait(callPayload, lateResult);
            if (session.closed || realtime?.closed) return;
            if (!shouldInjectLateToolResult(callPayload, lateResult)) return;
            const delivery = deliverLateToolResultToRealtime(realtime, callPayload, lateResult);
            if (!delivery.delivered) return;
            await session.safeEvent('tool_async_result_injected', compactPayload({
              ...correlationPayload(session, requestPayload, context),
              provider: 'gemini-live',
              tool_name: callPayload.name,
              tool_call_id: callPayload.id,
              request_id: lateResult.request_id,
              ok: lateResult.ok,
              delivery_channel: delivery.channel,
              result_keys: objectKeys(lateResult.result)
            }));
          }
        });
        dialogueDirector?.finishToolWait(callPayload, toolResult);
        await this.handleRealtimeToolAction({ call, session, requestPayload, toolResult, toolCall: callPayload });
        if (shouldWatchPostToolContinuation(toolResult)) postToolWatchdog.arm(callPayload, toolResult);
        return realtimeToolResponse(callPayload, toolResult);
      },
      onInterrupt: async (metadata = {}) => {
        const shouldClearOutput = shouldClearOutputBufferOnInterrupt(clearOutputOnInterrupt, {
          lastCallerTranscriptAt,
          lastCallerAudioAt,
          lastAiAudioAt,
          aiOutputActiveUntilMs,
          interruptionMode: context.ai?.interruption_mode || context.ai?.interruptionMode
        });
        const interruptMetadata = compactPayload({
          provider: 'gemini-live',
          reason: metadata.reason || metadata.source || 'vad_or_caller_speech',
          source: metadata.source || 'provider_interruption',
          clear_output_buffer: shouldClearOutput,
          last_caller_transcript_at: lastCallerTranscriptAt,
          last_caller_audio_at: lastCallerAudioAt,
          last_ai_transcript_at: lastAiTranscriptAt,
          last_ai_audio_at: lastAiAudioAt,
          stream_ref: streamRef,
          media_session_ref: mediaSessionRef
        });
        if (shouldClearOutput) {
          aiOutputActiveUntilMs = 0;
          outputPacer?.clear?.();
          await session.safeControl('caller_interrupted', interruptMetadata);
          return;
        }
        await session.safeEvent('realtime_interrupted', interruptMetadata);
      },
      onEvent: event => {
        // Do not disarm the post-tool continuation watchdog on provider
        // turnComplete alone. Gemini can complete the short tool-wait filler
        // turn ("Секунду, проверю") without actually answering from the tool
        // result; disarming here caused Voice Agent to stay silent/repeat tools.
        // The watchdog is cancelled by real model audio/transcript above.
        if (event?.close) {
          postToolWatchdog.cancel('provider_closed');
          const metadata = {
            provider: 'gemini-live',
            close_code: event.close.code,
            close_reason: event.close.reason
          };
          void session.safeEvent('provider_stream_closed', metadata);
          void completion?.finish?.('provider_stream_closed', metadata);
        } else if (event?.error) {
          postToolWatchdog.cancel('provider_error');
          const metadata = {
            provider: 'gemini-live',
            error_message: sanitizeReason(event.error.message || event.error.reason || 'provider_error')
          };
          void session.safeEvent('provider_error', metadata);
          void completion?.finish?.('provider_error', metadata);
        } else if (event?.serverContent?.interrupted) {
          void session.safeEvent('realtime_interrupted', compactPayload({
            provider: 'gemini-live',
            reason: event.serverContent.interruptionReason || event.serverContent.reason || 'vad_or_caller_speech',
            source: 'serverContent.interrupted',
            last_caller_transcript_at: lastCallerTranscriptAt,
            last_ai_transcript_at: lastAiTranscriptAt,
            last_ai_audio_at: lastAiAudioAt,
            stream_ref: streamRef,
            media_session_ref: mediaSessionRef
          }));
        }
      }
    };

    const realtime = this.realtimeFactory ? this.realtimeFactory({ session, context, ...callbacks }) : null;
    dialogueDirector = new DialogueDirector({
      context,
      session,
      requestPayload,
      sendText: text => realtime?.sendText?.(text)
    });
    if (!realtime || typeof realtime.connect !== 'function') {
      throw new Error('realtime client is required');
    }

    wireMediaInput(mediaStream, payload => {
      if (!acceptingInput || !payload || !payload.data || !isAudioIn(payload.type)) return;
      lastCallerAudioAt = new Date().toISOString();
      streamRef = payload.streamRef || payload.stream_ref || streamRef;
      session.streamRef = streamRef || session.streamRef;
      const sourceRate = audioRateFromMimeType(mimeTypeForStreamPayload(payload)) || FONOSTER_INPUT_RATE;
      const recordingInput = resamplePcm16(
        Buffer.from(payload.data),
        sourceRate,
        RECORDING_SAMPLE_RATE
      );
      writeRecordingAudio('inbound', recordingInput, {
        ...payload,
        stream_ref: payload.streamRef || payload.stream_ref || streamRef,
        media_session_ref: mediaSessionRef,
        source_rate: sourceRate,
        recording_sample_rate: RECORDING_SAMPLE_RATE
      });
      realtime.sendAudio(Buffer.from(payload.data), {
        mimeType: mimeTypeForStreamPayload(payload)
      });
    });

    completion = buildCompletion({
      call,
      mediaStream,
      outputPacer,
      realtime,
      session,
      recordingWriter,
      registry: this.registry,
      stopInput: () => { acceptingInput = false; },
      classifyCompletion: (action, metadata = {}) => {
        if (action !== 'media_stream_closed') return null;
        if (!lastMediaWriteAt) return null;

        return {
          action: 'session_completed',
          metadata: {
            ...metadata,
            reason: 'media_stream_closed',
            final_status: 'completed',
            incomplete_transcript: false,
            include_partial_transcript: false,
            media_stream_closed_after_audio: true,
            last_ai_audio_at: lastAiAudioAt,
            last_caller_audio_at: lastCallerAudioAt,
            last_media_write_at: lastMediaWriteAt
          }
        };
      },
      onFinish: () => {
        initialMediaKeepalive?.stop?.('completion');
        postToolWatchdog.cancel('completion');
        ordinaryAnswerWatchdog.cancel('completion');
        incompleteAnswerWatchdog.cancel('completion');
        businessFaqGate.cancel('completion');
        dialogueDirector?.close();
      }
    });
    try {
      await realtime.connect(callbacks);
      sendInitialGreeting(realtime, context);
    } catch (error) {
      try {
        dialogueDirector?.close?.();
      } catch (_closeError) {
        // ignore dialogue director cleanup errors
      }
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

  async handleMediaStreamEstablishmentFailure({ error, call, session, requestPayload = {}, routeDecision = {}, context = {} }) {
    const reason = sanitizeReason(error?.upstreamReason || error?.reason || error?.message || 'media_stream_not_established');
    const eventContext = context || routeDecision;

    if (!session.context) {
      session.context = compactPayload({
        account_id: routeDecision.account_id || routeDecision.accountId || session.accountId,
        number_ref: routeDecision.number_ref || routeDecision.numberRef || session.numberRef,
        conversation_id: routeDecision.conversation_id || routeDecision.conversationId
      });
    }

    if (error.upstreamReason === 'start_stream_response_timeout') {
      await session.safeEvent('start_stream_response_timeout', {
        reason: 'start_stream_response_timeout',
        source: error.source || 'fonoster_start_stream',
        timeout_ms: error.timeoutMs,
        ...correlationPayload(session, requestPayload, eventContext)
      });
    }
    await session.safeEvent('media_stream_not_established', {
      reason,
      source: error.source || 'call.stream',
      ...correlationPayload(session, requestPayload, eventContext)
    });
    await session.close('media_stream_not_established', {
      reason: 'media_stream_not_established',
      final_status: 'failed',
      incomplete_transcript: true,
      include_partial_transcript: true,
      source: error.source || 'call.stream'
    });
    this.registry?.close?.(session.callRef, 'media_stream_not_established');
    await hangupSafely(call, 'media_stream_not_established');
    return { session, context: session.context || context, mode: 'failed', completion: Promise.resolve(), reason: 'media_stream_not_established' };
  }

  async answerCallOrFail({ call, session, requestPayload = {}, routeDecision = {} }) {
    try {
      await answerCall(call, { timeoutMs: this.answerTimeoutMs });
      return null;
    } catch (error) {
      const reason = sanitizeReason(error?.reason || error?.message || 'app_answer_failed');
      await session.safeEvent('app_answer_failed', {
        reason,
        source: error?.source || 'call.answer',
        timeout_ms: error?.timeoutMs,
        ...correlationPayload(session, requestPayload, routeDecision)
      });
      await session.close('app_answer_failed', {
        reason,
        final_status: 'failed',
        incomplete_transcript: true,
        include_partial_transcript: true,
        source: error?.source || 'call.answer'
      });
      this.registry?.close?.(session.callRef, 'app_answer_failed');
      await hangupSafely(call, reason);
      return { session, context: session.context, mode: 'failed', completion: Promise.resolve(), reason };
    }
  }

  async startMediaStream(call, { session = null, requestPayload = {}, routeDecision = {} } = {}) {
    if (this.mediaStreamFactory) {
      try {
        const mediaStream = await this.mediaStreamFactory(call);
        if (mediaStream) return mediaStream;
      } catch (error) {
        throw mediaStreamEstablishmentError(error?.message || 'media stream factory failed', 'mediaStreamFactory');
      }
    }
    if (!call) {
      throw mediaStreamEstablishmentError('call is unavailable', 'call');
    }
    try {
      return await this.managedStreamStarter(call, {
        direction: streamConstants.bothDirection,
        format: streamConstants.wavFormat,
        onAudioOutWrite: firstAudioOutWriteReporter(session, requestPayload, routeDecision)
      });
    } catch (error) {
      const upstreamReason = error?.reason || error?.code || sanitizeReason(error?.message || '');
      const wrapped = mediaStreamEstablishmentError(
        upstreamReason || 'call.stream failed',
        error?.source || 'call.stream'
      );
      wrapped.upstreamReason = upstreamReason;
      wrapped.timeoutMs = error?.timeoutMs;
      throw wrapped;
    }
  }

  async startPassiveRecording(call, session, requestPayload = {}, routeContext = {}) {
    const recordingWriter = this.createRecordingWriter(session, requestPayload, routeContext);
    if (!recordingWriter) return null;

    try {
      const mediaStream = await this.startMediaStream(call);
      if (!mediaStream) return null;

      const mediaSessionRef = requestPayload.media_session_ref || requestPayload.mediaSessionRef || call?.request?.mediaSessionRef || session.callRef;
      await recordingWriter.start({ sampleRate: FONOSTER_CALL_RATE });
      wirePassiveRecording(mediaStream, recordingWriter, { mediaSessionRef });
      return { mediaStream, recordingWriter };
    } catch (error) {
      await session.safeEvent('recording_unavailable', {
        reason: sanitizeReason(error?.message || 'recording_stream_unavailable'),
        ...correlationPayload(session, requestPayload, routeContext)
      });
      return null;
    }
  }

  createRecordingWriter(session, requestPayload = {}, context = {}) {
    const contextRecording = context?.recording || {};
    const explicitlyEnabled = truthy(contextRecording.enabled) || truthy(requestPayload.recording_enabled) || truthy(requestPayload.recordingEnabled);
    if (!this.recordingEnabled && !explicitlyEnabled) return null;

    const options = {
      client: this.client,
      callRef: session.callRef,
      accountId: session.accountId,
      numberRef: session.numberRef,
      bridgeCallRef: session.bridgeCallRef,
      rootDir: contextRecording.root_dir || contextRecording.rootDir || process.env.VOICE_AGENT_RECORDING_ROOT
    };

    if (this.recordingWriterFactory) return this.recordingWriterFactory(options);
    return new RecordingWriter(options);
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

function wirePassiveRecording(mediaStream, recordingWriter, { mediaSessionRef } = {}) {
  wireMediaInput(mediaStream, payload => {
    if (!payload?.data) return;

    const streamRef = payload.streamRef || payload.stream_ref || mediaStream?.streamRef;
    const metadata = {
      ...payload,
      stream_ref: streamRef,
      media_session_ref: payload.mediaSessionRef || payload.media_session_ref || mediaSessionRef
    };
    const chunk = recordingChunkForPayload(payload);
    if (chunk.length === 0) return;

    if (isAudioIn(payload.type)) {
      void recordingWriter?.writeInbound?.(chunk, metadata);
    } else if (isAudioOut(payload.type)) {
      void recordingWriter?.writeOutbound?.(chunk, metadata);
    }
  });
}

function recordingChunkForPayload(payload = {}) {
  const buffer = Buffer.from(payload.data || []);
  const sourceRate = audioRateFromMimeType(payload.mimeType) || (isAudioOut(payload.type) ? FONOSTER_CALL_RATE : FONOSTER_INPUT_RATE);
  return resamplePcm16(buffer, sourceRate, FONOSTER_CALL_RATE);
}

async function closePassiveRecording(passiveRecording) {
  if (!passiveRecording) return;
  try {
    await passiveRecording.recordingWriter?.close?.({ endedAt: new Date() });
  } catch (_error) {
    // Recording finalization is best effort and must not block call cleanup.
  }
  closeMediaStreamSafely(passiveRecording.mediaStream);
}

function closeMediaStreamSafely(mediaStream) {
  try {
    mediaStream?.close?.();
  } catch (_error) {
    // ignore media stream cleanup errors
  }
}

function firstAudioOutWriteReporter(session, requestPayload = {}, routeDecision = {}) {
  if (!session || typeof session.safeEvent !== 'function') return null;

  let reported = false;
  return metadata => {
    if (reported) return;
    reported = true;
    void session.safeEvent('first_audio_out_write', {
      ...correlationPayload(session, requestPayload, routeDecision),
      ...metadata
    });
  };
}

function startInitialMediaKeepalive({ mediaStream, session, requestPayload = {}, durationMs = 0, frameMs = 20 } = {}) {
  const maxDurationMs = Number(durationMs) || 0;
  if (!mediaStream || typeof mediaStream.write !== 'function' || maxDurationMs <= 0) return null;

  let streamRef = String(mediaStream.streamRef || mediaStream.stream_ref || requestPayload.stream_ref || requestPayload.streamRef || '').trim();
  let mediaSessionRef = String(mediaStream.mediaSessionRef || mediaStream.media_session_ref || requestPayload.media_session_ref || requestPayload.mediaSessionRef || session?.callRef || '').trim();
  if (!streamRef) return null;

  const frameBytes = pcm16FrameBytes(FONOSTER_CALL_RATE, frameMs);
  const silenceFrame = Buffer.alloc(frameBytes);
  const startedAt = Date.now();
  let stopped = false;
  let timer = null;
  let framesWritten = 0;

  const stop = reason => {
    if (stopped) return;
    stopped = true;
    clearTimer(timer);
    timer = null;
    if (framesWritten > 0) {
      void session?.safeEvent?.('media_keepalive_stopped', {
        reason,
        frames_written: framesWritten,
        duration_ms: Math.max(0, Date.now() - startedAt),
        stream_ref: streamRef,
        media_session_ref: mediaSessionRef
      });
    }
  };

  const reportFailure = (reason, error) => {
    void session?.safeEvent?.('media_keepalive_failed', {
      reason,
      error_message: sanitizeReason(error?.message || error?.reason || reason),
      error_code: error?.code,
      stream_ref: streamRef,
      media_session_ref: mediaSessionRef
    });
    stop(reason);
  };

  const writeSilence = () => {
    if (stopped) return;
    if (Date.now() - startedAt >= maxDurationMs) {
      stop('timeout');
      return;
    }

    try {
      const result = mediaStream.write({
        mediaSessionRef,
        streamRef,
        format: streamConstants.wavFormat,
        type: streamConstants.audioOut,
        kind: 'keepalive_silence',
        data: silenceFrame
      });
      framesWritten += 1;
      if (framesWritten === 1) {
        void session?.safeEvent?.('media_keepalive_started', {
          stream_ref: streamRef,
          media_session_ref: mediaSessionRef,
          output_format: streamConstants.wavFormat,
          output_encoding: 'pcm_s16le',
          telephony_output_rate: FONOSTER_CALL_RATE,
          frame_ms: frameMs,
          frame_bytes: frameBytes,
          max_duration_ms: maxDurationMs
        });
      }
      if (result && typeof result.then === 'function') {
        result.catch(error => reportFailure('media_keepalive_write_failed', error));
      }
    } catch (error) {
      reportFailure('media_keepalive_write_failed', error);
    }
  };

  writeSilence();
  if (!stopped) {
    timer = setInterval(writeSilence, frameMs);
    timer.unref?.();
  }

  return {
    stop,
    updateRefs(refs = {}) {
      streamRef = String(refs.streamRef || refs.stream_ref || streamRef || '').trim();
      mediaSessionRef = String(refs.mediaSessionRef || refs.media_session_ref || mediaSessionRef || '').trim();
    }
  };
}

function buildPassiveRecordingCompletion({ call, passiveRecording }) {
  if (!passiveRecording || !call || typeof call.on !== 'function') return Promise.resolve();

  return new Promise(resolve => {
    let completed = false;
    const finish = async () => {
      if (completed) return;
      completed = true;
      try {
        await closePassiveRecording(passiveRecording);
      } finally {
        resolve();
      }
    };

    for (const eventName of callEndEvents()) registerOnce(call, eventName, () => { void finish(); });
  });
}

function buildOperatorCompletion({ call, dialResult, session, requestPayload, routeDecision, app, registry, passiveRecording = null }) {
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
      await closePassiveRecording(passiveRecording);
      await app.safeBridgeEvent(event, session, requestPayload, routeDecision, metadata);
      registry?.close?.(session.callRef, terminalOperatorState(event));
      resolve();
    };

    const failOrFallback = async (event, reason) => {
      if (completed) return;
      completed = true;
      clearTimer(timeout);
      try {
        await closePassiveRecording(passiveRecording);
        await app.handleOperatorFailure(call, session, requestPayload, routeDecision, reason, event);
        registry?.close?.(session.callRef, reason);
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
      void closePassiveRecording(passiveRecording).finally(resolve);
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

function createOrdinaryAnswerWatchdog({ timeoutMs = 2_500, session, requestPayload = {}, context = {}, sendContinuation = null } = {}) {
  let timer = null;
  let sequence = 0;
  const normalizedTimeout = Number.parseInt(timeoutMs, 10);
  const enabledTimeout = Number.isFinite(normalizedTimeout) && normalizedTimeout > 0 ? normalizedTimeout : 0;

  const cancel = (_reason = 'cancelled') => {
    if (!timer) return;
    clearTimer(timer);
    timer = null;
  };

  const arm = (transcript = {}) => {
    if (!enabledTimeout || session?.closed || !isMeaningfulCallerText(transcript.text)) return;
    cancel('rearmed');
    const currentSequence = ++sequence;
    const metadata = compactPayload({
      ...correlationPayload(session, requestPayload, context),
      provider: transcript.provider || 'gemini-live',
      caller_transcript: summarizeCallerText(transcript.text),
      timeout_ms: enabledTimeout
    });

    timer = setTimer(() => {
      if (currentSequence !== sequence || session?.closed) return;
      timer = null;
      void session.safeControl('ordinary_answer_model_stall', metadata);
      try {
        sendContinuation?.(ordinaryAnswerContinuationPrompt(transcript.text));
      } catch (_error) {
        // Continuation is best effort; diagnostics above are persisted through Rails.
      }
    }, enabledTimeout);
  };

  return { arm, cancel };
}

function createBusinessFaqGate({ delayMs = 650, session, requestPayload = {}, context = {}, executeTool = null, foregroundTimeoutMs = null, sendContinuation = null } = {}) {
  let timer = null;
  let inFlight = null;
  let completed = null;
  let sequence = 0;
  const normalizedDelay = Number.parseInt(delayMs, 10);
  const enabledDelay = Number.isFinite(normalizedDelay) && normalizedDelay >= 0 ? normalizedDelay : 0;

  const cancel = (_reason = 'cancelled') => {
    if (!timer) return;
    clearTimer(timer);
    timer = null;
  };

  const consumeToolCall = (callPayload = {}) => {
    if (String(callPayload.name || '').trim().toLowerCase() !== 'faq_lookup') return null;
    if (inFlight) return inFlight.promise;
    if (completed && completed.expiresAt > Date.now()) return completed.promise;
    completed = null;
    return null;
  };

  const consider = transcript => {
    if (!hasTool(context, 'faq_lookup') || !shouldGateFaqLookup(transcript?.text) || typeof executeTool !== 'function') return;
    cancel('rearmed');
    completed = null;
    const currentSequence = ++sequence;
    const query = String(transcript.text || '').trim();
    const gateId = `business_faq_gate:${currentSequence}`;

    timer = setTimer(() => {
      if (currentSequence !== sequence || session?.closed) return;
      timer = null;
      void fire(query, gateId, transcript);
    }, enabledDelay);
  };

  const fire = (query, gateId, transcript = {}) => {
    const metadata = compactPayload({
      ...correlationPayload(session, requestPayload, context),
      provider: transcript.provider || 'gemini-live',
      reason: 'business_faq_gate',
      tool_name: 'faq_lookup',
      tool_call_id: gateId,
      caller_transcript: summarizeCallerText(query)
    });
    const promise = (async () => {
      await session.safeControl('business_faq_gate_fired', metadata);
      const toolResult = await executeTool('faq_lookup', { query }, {
        provider: 'gemini-live',
        tool_call_id: gateId,
        reason: 'business_faq_gate',
        foreground_timeout_ms: typeof foregroundTimeoutMs === 'function' ? foregroundTimeoutMs('faq_lookup') : undefined,
        onAsyncResult: async lateResult => {
          if (session.closed || !shouldInjectLateToolResult({ name: 'faq_lookup' }, lateResult)) return;
          const prompt = lateToolResultPrompt({ name: 'faq_lookup' }, lateResult);
          if (!prompt) return;
          sendContinuation?.(prompt);
          await session.safeEvent('business_faq_gate_result_injected', compactPayload({
            ...metadata,
            request_id: lateResult.request_id,
            ok: lateResult.ok,
            async: true
          }));
        }
      });
      if (session.closed || !toolResult?.ok) return toolResult;
      const prompt = lateToolResultPrompt({ name: 'faq_lookup' }, { ok: true, async: true, result: toolResult.result });
      if (!prompt) return toolResult;
      sendContinuation?.(prompt);
      await session.safeEvent('business_faq_gate_result_injected', compactPayload({
        ...metadata,
        ok: true,
        async: false,
        result_keys: objectKeys(toolResult.result)
      }));
      return toolResult;
    })().then(result => {
      completed = { gateId, promise: Promise.resolve(result), expiresAt: Date.now() + 5_000 };
      return result;
    }).catch(error => {
      const result = { ok: false, error: sanitizeReason(error?.message || 'business_faq_gate_failed') };
      completed = { gateId, promise: Promise.resolve(result), expiresAt: Date.now() + 5_000 };
      return result;
    }).finally(() => {
      if (inFlight?.gateId === gateId) inFlight = null;
    });
    inFlight = { gateId, promise };
    return promise;
  };

  return { consider, cancel, consumeToolCall };
}

function createPostToolWatchdog({ timeoutMs = 4_000, session, requestPayload = {}, context = {}, sendContinuation = null } = {}) {
  let timer = null;
  let sequence = 0;
  const normalizedTimeout = Number.parseInt(timeoutMs, 10);
  const enabledTimeout = Number.isFinite(normalizedTimeout) && normalizedTimeout > 0 ? normalizedTimeout : 0;

  const cancel = (_reason = 'cancelled') => {
    if (!timer) return;
    clearTimer(timer);
    timer = null;
  };

  const arm = (toolCall = {}, toolResult = {}) => {
    if (!enabledTimeout || session?.closed) return;
    cancel('rearmed');
    const currentSequence = ++sequence;
    const metadata = compactPayload({
      ...correlationPayload(session, requestPayload, context),
      provider: 'gemini-live',
      tool_name: toolCall.name,
      tool_call_id: toolCall.id,
      timeout_ms: enabledTimeout,
      tool_ok: toolResult.ok,
      result_keys: objectKeys(toolResult.result)
    });

    timer = setTimer(() => {
      if (currentSequence !== sequence || session?.closed) return;
      timer = null;
      void session.safeControl('post_tool_model_stall', metadata);
      try {
        sendContinuation?.(postToolContinuationPrompt(toolCall, toolResult));
      } catch (_error) {
        // Continuation is best effort; diagnostics above are persisted through Rails.
      }
    }, enabledTimeout);
  };

  return { arm, cancel };
}

function createIncompleteAnswerWatchdog({ timeoutMs = 1_200, session, requestPayload = {}, context = {}, sendContinuation = null } = {}) {
  let timer = null;
  let sequence = 0;
  const normalizedTimeout = Number.parseInt(timeoutMs, 10);
  const enabledTimeout = Number.isFinite(normalizedTimeout) && normalizedTimeout > 0 ? normalizedTimeout : 0;

  const cancel = (_reason = 'cancelled') => {
    if (!timer) return;
    clearTimer(timer);
    timer = null;
  };

  const arm = (transcript = {}) => {
    const text = String(transcript.text || '').trim();
    if (!enabledTimeout || session?.closed || !isLikelyIncompleteAnswer(text)) return;
    cancel('rearmed');
    const currentSequence = ++sequence;
    const metadata = compactPayload({
      ...correlationPayload(session, requestPayload, context),
      provider: transcript.provider || 'gemini-live',
      timeout_ms: enabledTimeout,
      last_ai_text: summarizeCallerText(text)
    });

    timer = setTimer(() => {
      if (currentSequence !== sequence || session?.closed) return;
      timer = null;
      void session.safeControl('incomplete_answer_model_stall', metadata);
      try {
        sendContinuation?.(incompleteAnswerContinuationPrompt(text));
      } catch (_error) {
        // Continuation is best effort; persisted control event above is the RCA anchor.
      }
    }, enabledTimeout);
  };

  return { arm, cancel };
}

function shouldWatchPostToolContinuation(toolResult = {}) {
  if (!toolResult?.ok) return false;
  const action = String(toolResult.result?.action || '').trim().toLowerCase();
  return !['transfer', 'end_call', 'hangup'].includes(action);
}

const DEFAULT_READ_TOOL_FOREGROUND_WAIT_MS = 900;

function foregroundToolWaitMs(context = {}, toolName = '') {
  if (isSideEffectToolName(toolName)) return null;
  const tool = Array.isArray(context.tools)
    ? context.tools.find(candidate => String(candidate?.name || '').trim() === String(toolName || '').trim())
    : null;
  const explicitToolWaitMs = parsePositiveInt(tool?.foreground_wait_ms ?? tool?.foregroundWaitMs);
  if (explicitToolWaitMs) return explicitToolWaitMs;
  if (!isReadLikeToolName(toolName)) return null;

  const globalReadWaitMs = parsePositiveInt(context.ai?.tool_foreground_wait_ms ?? context.ai?.toolForegroundWaitMs);
  // Read-only Rails/Captain tools commonly finish in 400-700ms; do not let
  // legacy/global 350ms settings create a user-facing failure before the
  // normal result arrives. Tool-specific foreground_wait_ms remains an explicit
  // opt-in above for tests or intentionally async tools.
  return Math.max(globalReadWaitMs || 0, DEFAULT_READ_TOOL_FOREGROUND_WAIT_MS);
}

function shouldInjectLateToolResult(toolCall = {}, lateResult = {}) {
  if (!lateResult?.async) return false;
  if (isSideEffectToolName(toolCall.name)) return false;
  const action = String(lateResult.result?.action || '').trim().toLowerCase();
  return !['transfer', 'end_call', 'hangup'].includes(action);
}

function deliverLateToolResultToRealtime(realtime, toolCall = {}, lateResult = {}) {
  const response = realtimeToolResponse(toolCall, lateResult);
  const prompt = lateToolResultPrompt(toolCall, lateResult);
  let sentToolResponse = false;

  if (toolCall.id && typeof realtime?.sendToolResponse === 'function') {
    try {
      realtime.sendToolResponse(toolCall.id, response, toolCall.name);
      sentToolResponse = true;
    } catch (_error) {
      sentToolResponse = false;
    }
  }

  let sentText = false;
  if (prompt && typeof realtime?.sendText === 'function') {
    try {
      realtime.sendText(prompt);
      sentText = true;
    } catch (_error) {
      sentText = false;
    }
  }

  return {
    delivered: sentToolResponse || sentText,
    channel: sentToolResponse && sentText ? 'tool_response_and_text' : (sentToolResponse ? 'tool_response' : (sentText ? 'text' : null))
  };
}

function realtimeToolResponse(toolCall = {}, toolResult = {}) {
  if (toolResult?.pending) {
    return {
      ok: true,
      pending: true,
      async: true,
      request_id: toolResult.request_id || toolCall.id,
      tool_name: toolCall.name,
      message: 'Tool request accepted and is still running. Wait for the async result before using this information.'
    };
  }
  return toolResult;
}

function lateToolResultPrompt(toolCall = {}, lateResult = {}) {
  const toolName = String(toolCall.name || lateResult.tool_name || 'инструмента').trim();
  if (lateResult.ok === false) {
    const reason = summarizeCallerText(sanitizeReason(lateResult.error || 'инструмент временно недоступен'));
    return `Результат инструмента ${toolName}: ошибка. Коротко скажи клиенту, что не удалось проверить данные сейчас, и предложи уточнить вопрос или соединить со специалистом. Причина: ${reason}`;
  }
  const answer = summarizeToolResult(lateResult.result);
  if (!answer) return '';
  return `Результат инструмента ${toolName} готов. Используй его в следующей голосовой реплике клиенту, коротко и естественно по-русски. Не перечисляй служебные поля. Результат: ${answer}`;
}

function isSideEffectToolName(name = '') {
  const normalized = String(name || '').trim().toLowerCase();
  if (!normalized) return false;
  if (['request_transfer', 'transfer', 'handoff', 'end_call', 'hangup'].includes(normalized)) return true;
  return /^(create|update|delete|set|assign|add|remove)_/.test(normalized);
}

function isReadLikeToolName(name = '') {
  const normalized = String(name || '').trim().toLowerCase();
  return /(^|_)(find|lookup|search|list|get|read|fetch|faq)(_|$)/.test(normalized) || normalized === 'faq_lookup';
}

function postToolContinuationPrompt(toolCall = {}, toolResult = {}) {
  const toolName = String(toolCall.name || 'инструмента').trim();
  const answer = summarizeToolResult(toolResult.result);
  return `Продолжи голосовой ответ клиенту после результата ${toolName}. Не молчи, скажи коротко и естественно по-русски.${answer ? ` Учитывай результат: ${answer}` : ''}`;
}

function ordinaryAnswerContinuationPrompt(text = '') {
  const question = summarizeCallerText(text);
  return `Ответь клиенту сейчас коротко и естественно по-русски. Не молчи и не обрывай фразу.${question ? ` Последний вопрос клиента: ${question}` : ''}`;
}

function incompleteAnswerContinuationPrompt(text = '') {
  const lastText = summarizeCallerText(text);
  return `Договори последнюю голосовую реплику клиенту. Продолжи с места обрыва, коротко и естественно по-русски, без повторения всей фразы.${lastText ? ` Оборванная фраза: ${lastText}` : ''}`;
}

function isLikelyIncompleteAnswer(text = '') {
  const normalized = normalizeSpokenText(text);
  if (normalized.length < 18) return false;
  if (/[.!?…]$/.test(String(text || '').trim())) return false;
  const lastWord = normalized.split(/\s+/).filter(Boolean).pop();
  return new Set([
    'в', 'во', 'на', 'к', 'ко', 'с', 'со', 'у', 'от', 'до', 'для', 'по', 'при', 'про', 'через', 'между',
    'и', 'или', 'а', 'но', 'что', 'чтобы', 'если', 'когда', 'где', 'как', 'который', 'которая', 'которые',
    'потому', 'поэтому', 'это', 'этапе', 'статусе', 'воронке', 'составляет', 'будет', 'можно', 'нужно',
    'должен', 'должна', 'должны'
  ]).has(lastWord);
}

function hasTool(context = {}, toolName = '') {
  const expected = String(toolName || '').trim().toLowerCase();
  return Array.isArray(context.tools) && context.tools.some(tool => String(tool?.name || '').trim().toLowerCase() === expected);
}

function shouldGateFaqLookup(text = '') {
  const normalized = normalizeSpokenText(text);
  if (!isMeaningfulCallerText(normalized)) return false;
  if (/\b(оператор|менеджер|человек|живой|переведи|соедини|transfer)\b/i.test(normalized)) return false;
  return /\b(цена|цены|стоимост|сколько стоит|прайс|тариф|режим|график|адрес|где находится|локац|услуг|доставка|оплат|гаранти|акци|скидк|услови|документ|срок|слоган|название|телефон|номер|whatsapp|ватсап|инстаграм|instagram|сайт|работаете|открыт|закрыт)\b/i.test(normalized) ||
    /^(какой|какая|какие|как|где|когда|сколько|есть ли|можно ли|что у вас)/i.test(normalized);
}

function isMeaningfulCallerText(text = '') {
  const normalized = normalizeSpokenText(text);
  return normalized.length >= 8 && !/^(алло|привет|здравствуйте|добрый день|да|нет|угу|ага|ок|спасибо)$/.test(normalized);
}

function summarizeCallerText(text = '') {
  return String(text || '').trim().replace(/\s+/g, ' ').slice(0, 180);
}

function summarizeToolResult(result) {
  if (!result) return '';
  if (typeof result === 'string') {
    const parsed = parseJsonObject(result);
    return parsed ? summarizeToolResult(parsed) : result.slice(0, 240);
  }
  if (typeof result !== 'object') return '';
  if (result.result) {
    const nested = summarizeToolResult(result.result);
    if (nested) return nested;
  }
  for (const key of ['answer', 'text', 'summary', 'message']) {
    if (result[key]) return String(result[key]).slice(0, 240);
  }
  if (Number(result.total_count) === 0 || (Array.isArray(result.matches) && result.matches.length === 0)) {
    return 'по этому запросу ничего не найдено; скажи клиенту это коротко и предложи уточнить вопрос или соединить со специалистом';
  }
  if (Array.isArray(result.matches) && result.matches.length > 0) {
    return result.matches.slice(0, 2).map(item => item.answer || item.text || item.title || item.content).filter(Boolean).join(' ').slice(0, 240);
  }
  if (Array.isArray(result.pipelines) && result.pipelines.length > 0) {
    const names = result.pipelines.slice(0, 4).map(item => item.name).filter(Boolean).join(', ');
    return names ? `доступные воронки: ${names}` : '';
  }
  if (result.deal && result.deal.id) return `сделка создана, id ${result.deal.id}`;
  return '';
}

function parseJsonObject(value) {
  try {
    const parsed = JSON.parse(value);
    return parsed && typeof parsed === 'object' ? parsed : null;
  } catch (_error) {
    return null;
  }
}

function isToolWaitFillerTranscript(text, settings = {}) {
  const normalizedText = normalizeSpokenText(text);
  if (!normalizedText) return false;
  const phrases = [
    settings?.tool_start_phrases,
    settings?.tool_delay_phrases,
    settings?.tool_failure_phrases
  ].flatMap(value => (Array.isArray(value) ? value : [value]));

  return phrases.some(phrase => normalizeSpokenText(phrase) === normalizedText);
}

function recentToolWaitFillerTranscript(now, lastFillerAt) {
  return lastFillerAt > 0 && now - lastFillerAt < 1_500;
}

function normalizeSpokenText(value) {
  return String(value || '')
    .trim()
    .toLowerCase()
    .replace(/[.!?…]+$/g, '')
    .replace(/\s+/g, ' ');
}

function objectKeys(value) {
  return value && typeof value === 'object' ? Object.keys(value).slice(0, 20) : [];
}

function buildCompletion({ call, mediaStream, outputPacer, realtime, session, recordingWriter = null, registry, stopInput = null, classifyCompletion = null, onFinish = null }) {
  let resolveCompletion;
  const completion = new Promise(resolve => { resolveCompletion = resolve; });
  let completed = false;

  const finish = async (action = 'session_completed', metadata = {}) => {
    if (completed) return;
    completed = true;
    const initialAction = completionAction(session, action);
    const classification = classifyCompletion?.(initialAction, metadata) || {};
    const finalAction = classification.action || initialAction;
    const finalMetadata = completionMetadata(session, finalAction, {
      ...metadata,
      ...(classification.metadata || {})
    });

    try {
      onFinish?.(finalAction, finalMetadata);
    } catch (_error) {
      // ignore completion hook errors
    }

    try {
      stopInput?.();
    } catch (_error) {
      // ignore input-gate cleanup errors
    }

    if (shouldDrainOutput(finalAction)) {
      try {
        await outputPacer?.drain?.({ timeoutMs: 2_000 });
      } catch (_error) {
        // Fall through to close; preserving lifecycle beats drain failures.
      }
    }

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
      await mediaStream?.close?.();
    } catch (_error) {
      // ignore stream cleanup errors
    }
    try {
      await recordingWriter?.close?.({ endedAt: new Date() });
    } catch (_error) {
      // recording_ready/error reporting is best effort and must not block call cleanup
    }
    try {
      await session.safeEvent('call_ended', { reason: finalAction, ...finalMetadata });
    } catch (_error) {
      // event persistence errors should not block media cleanup
    }
    try {
      await session.close(finalAction, finalMetadata);
    } catch (_error) {
      // transcript/control persistence errors should not block media cleanup
    }
    registry?.close?.(session.callRef, finalAction);
    resolveCompletion();
  };

  completion.finish = finish;

  let registered = false;
  registered = registerCallCompletion(call, finish) || registered;

  if (mediaStream) {
    if (typeof mediaStream.cleanup === 'function') {
      mediaStream.cleanup(() => { void finish('media_stream_closed', { source: 'mediaStream.cleanup' }); });
      registered = true;
    }

    if (typeof mediaStream.on === 'function' || typeof mediaStream.once === 'function') {
      registered = registerStreamCompletion(mediaStream, finish) || registered;
    }
  }

  if (!registered) {
    resolveCompletion();
  }

  return completion;
}

function completionAction(session, action) {
  if (session?.transferState?.connected && ['session_completed', 'caller_hangup', 'fonoster_call_closed'].includes(action)) return 'transfer_completed';
  return action || 'session_completed';
}

function completionMetadata(session, action, metadata = {}) {
  const base = {
    ...metadata,
    reason: metadata.reason || action,
    incomplete_transcript: action !== 'session_completed' && action !== 'transfer_completed',
    include_partial_transcript: action !== 'session_completed' && action !== 'transfer_completed',
    final_status: metadata.final_status || finalStatusForCompletionAction(action)
  };

  if (!session?.transferState?.connected || action !== 'transfer_completed') return base;

  return {
    ...base,
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

function finalStatusForCompletionAction(action) {
  const normalized = String(action || '').toLowerCase();
  if (normalized.includes('caller_hangup')) return 'caller_hung_up';
  if (normalized.includes('media_stream_not_established')) return 'failed';
  if (normalized.includes('media_stream_closed') || normalized.includes('media_stream_framing_error') || normalized.includes('provider_stream_closed') || normalized.includes('provider_error')) return 'failed';
  if (normalized.includes('fonoster_call_closed') || normalized.includes('runtime_closed')) return 'cancelled';
  if (normalized.includes('failed')) return 'failed';
  if (normalized.includes('transfer')) return 'transferred';
  return 'completed';
}

function shouldDrainOutput(action) {
  const normalized = String(action || '').toLowerCase();
  if (normalized.includes('caller_hangup') || normalized.includes('media_stream_closed') || normalized.includes('media_stream_framing_error') || normalized.includes('media_stream_not_established') || normalized.includes('fonoster_call_closed')) return false;
  if (normalized.includes('provider_error') || normalized.includes('session_failed') || normalized.includes('transfer')) return false;
  return true;
}

function registerCallCompletion(call, finish) {
  const targets = [call, call?.voice].filter(Boolean);
  let registered = false;
  for (const target of targets) {
    for (const eventName of callEndEvents()) {
      registered = registerOnce(target, eventName, () => { void finish(callCompletionAction(eventName), { source: `call.${eventName}` }); }) || registered;
    }
    for (const eventName of callErrorEvents()) {
      registered = registerOnce(target, eventName, () => { void finish('session_failed', { source: `call.${eventName}` }); }) || registered;
    }
  }
  return registered;
}

function registerStreamCompletion(mediaStream, finish) {
  let registered = false;
  for (const eventName of ['end', 'close', 'END', 'CLOSE']) {
    registered = registerOnce(mediaStream, eventName, () => { void finish('media_stream_closed', { source: `mediaStream.${eventName}` }); }) || registered;
  }
  for (const eventName of ['error', 'ERROR']) {
    registered = registerOnce(mediaStream, eventName, error => {
      const action = mediaStreamErrorAction(error);
      void finish(action, compactPayload({
        source: `mediaStream.${eventName}`,
        error_message: sanitizeReason(error?.message || error?.reason || action),
        error_code: error?.code
      }));
    }) || registered;
  }
  return registered;
}

function mediaStreamErrorAction(error) {
  const message = String(error?.message || error?.reason || error?.code || '').toLowerCase();
  if (message.includes('wrong number of bytes') || message.includes('payload') || message.includes('frame')) {
    return 'media_stream_framing_error';
  }
  return 'session_failed';
}

function mediaWriteFailureReason(error, fallback) {
  return mediaStreamErrorAction(error) === 'media_stream_framing_error' ? 'media_stream_framing_error' : fallback;
}

function callCompletionAction(eventName) {
  const normalized = String(eventName || '').toLowerCase();
  if (normalized.includes('hangup') || normalized === 'end' || normalized === 'close') return 'caller_hangup';
  return 'fonoster_call_closed';
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

function isAudioOut(type) {
  return [streamConstants.audioOut, 'audio_out', 'AUDIO_OUT', 'out'].includes(type);
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

function pcm16FrameBytes(sampleRate, frameMs) {
  const bytes = Math.max(2, Math.round((Number(sampleRate || 0) * Number(frameMs || 0) * 2) / 1000));
  return bytes % 2 === 0 ? bytes : bytes + 1;
}

function validatePcm16Frame(frame, expectedFrameBytes) {
  if (!Buffer.isBuffer(frame)) return 'media_frame_not_buffer';
  if (frame.length !== expectedFrameBytes) return 'media_frame_size_mismatch';
  if (frame.length % 2 !== 0) return 'media_frame_unaligned_pcm16';
  if (looksLikeWavHeader(frame)) return 'media_frame_contains_wav_header';
  return null;
}

function looksLikeWavHeader(buffer) {
  return buffer.length >= 12 &&
    buffer.subarray(0, 4).toString('ascii') === 'RIFF' &&
    buffer.subarray(8, 12).toString('ascii') === 'WAVE';
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

function parsePositiveInt(value, fallback = 0) {
  const parsed = Number.parseInt(value, 10);
  return Number.isFinite(parsed) && parsed > 0 ? parsed : fallback;
}

function envFlag(name) {
  return truthy(process.env[name]);
}

function truthy(value) {
  if (value === true) return true;
  if (value === false || value === undefined || value === null) return false;
  return ['1', 'true', 'yes', 'on', 'enabled'].includes(String(value).trim().toLowerCase());
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
  constructor({ sampleRate, frameMs = 20, maxBufferedMs = 15_000, onFrame, onDrop = null }) {
    this.sampleRate = Number(sampleRate) || 8_000;
    this.frameMs = Number(frameMs) || 20;
    this.frameBytes = Math.max(2, Math.round((this.sampleRate * this.frameMs * 2) / 1000));
    if (this.frameBytes % 2 !== 0) this.frameBytes += 1;
    this.maxBufferedMs = Number(maxBufferedMs) || 15_000;
    this.maxBufferedBytes = Math.max(this.frameBytes, Math.round((this.sampleRate * 2 * this.maxBufferedMs) / 1000));
    this.onFrame = onFrame;
    this.onDrop = onDrop;
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
      const droppedBytes = Math.min(alignedOverflow, this.buffer.length);
      this.buffer = this.buffer.subarray(droppedBytes);
      this.onDrop?.({
        reason: 'overflow',
        dropped_bytes: droppedBytes,
        buffered_bytes: this.buffer.length,
        max_buffered_ms: this.maxBufferedMs
      });
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
    const frame = Buffer.from(this.buffer.subarray(0, this.frameBytes));
    this.buffer = this.buffer.subarray(this.frameBytes);
    this.onFrame?.(frame);
  }

  drain({ timeoutMs = 2_000 } = {}) {
    if (this.closed || this.buffer.length === 0) return Promise.resolve({ drained: true });
    this.start();
    return new Promise(resolve => {
      const deadline = Date.now() + Math.max(0, Number(timeoutMs) || 0);
      const check = setInterval(() => {
        if (this.closed) {
          clearInterval(check);
          resolve({ drained: false, reason: 'closed' });
          return;
        }
        if (this.buffer.length > 0 && this.buffer.length < this.frameBytes) {
          const frame = Buffer.alloc(this.frameBytes);
          this.buffer.copy(frame);
          this.buffer = Buffer.alloc(0);
          this.onFrame?.(frame);
        }
        if (this.buffer.length === 0) {
          clearInterval(check);
          resolve({ drained: true });
          return;
        }
        if (Date.now() >= deadline) {
          clearInterval(check);
          this.onDrop?.({
            reason: 'drain_timeout',
            dropped_bytes: this.buffer.length,
            buffered_bytes: this.buffer.length,
            max_buffered_ms: this.maxBufferedMs
          });
          resolve({ drained: false, reason: 'timeout', dropped_bytes: this.buffer.length });
        }
      }, this.frameMs);
    });
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
    bridge_call_ref: bridgeCallRefCandidate(requestPayload),
    ingress_number: requestPayload.ingress_number || requestPayload.ingressNumber || requestPayload.to_number || requestPayload.to,
    caller_number: requestPayload.caller_number || requestPayload.callerNumber || requestPayload.from_number || requestPayload.from,
    number_ref: requestPayload.number_ref || requestPayload.numberRef,
    account_id: requestPayload.account_id || requestPayload.accountId,
    app_ref: requestPayload.app_ref || requestPayload.appRef,
    media_session_ref: requestPayload.media_session_ref || requestPayload.mediaSessionRef
  });
}

function providedRouteDecision(requestPayload = {}) {
  const candidate = requestPayload.routing || requestPayload.route_decision || requestPayload.routeDecision;
  if (!candidate || typeof candidate !== 'object') return null;
  const action = candidate.action || candidate.mode || 'ai';
  return {
    ...candidate,
    action,
    mode: candidate.mode || action,
    reason: candidate.reason || 'whatsapp_cloud_pre_routed'
  };
}

function bridgeEventPayload(event, session, requestPayload = {}, routeDecision = {}, metadata = {}) {
  return compactPayload({
    event_key: `runtime:${session.callRef}:${event}`,
    event,
    call_ref: session.callRef,
    bridge_call_ref: session.bridgeCallRef || bridgeCallRefCandidate(requestPayload) || bridgeCallRefCandidate(routeDecision),
    runtime_call_ref: session.callRef,
    ai_runtime_call_ref: session.callRef,
    media_session_ref: session.mediaSessionRef || requestPayload.media_session_ref || requestPayload.mediaSessionRef,
    stream_ref: session.streamRef || requestPayload.stream_ref || requestPayload.streamRef,
    account_id: session.accountId || requestPayload.account_id || requestPayload.accountId,
    number_ref: session.numberRef || requestPayload.number_ref || requestPayload.numberRef,
    app_ref: selectedAppRef(requestPayload, routeDecision),
    ingress_number: session.ingressNumber || requestPayload.ingress_number || requestPayload.ingressNumber || requestPayload.to,
    caller_number: session.callerNumber || requestPayload.caller_number || requestPayload.callerNumber || requestPayload.from,
    metadata: {
      ...operatorRouteMetadata(routeDecision),
      ...metadata,
      route_app_ref: routeAppRef(routeDecision),
      selected_app_ref: selectedAppRef(requestPayload, routeDecision),
      topology: directAiTopology(requestPayload, routeDecision),
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
  session.bridgeCallRef = bridgeCallRefCandidate(routeDecision) || session.bridgeCallRef;
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

async function hangupSafely(call, reason) {
  try {
    if (typeof call?.hangup === 'function') return await call.hangup({ reason });
    if (typeof call?.reject === 'function') return await call.reject({ reason });
    if (typeof call?.close === 'function') return await call.close();
  } catch (_error) {
    // Terminal persistence is more important than propagating provider cleanup errors.
  }
  return false;
}

function shouldClearOutputBufferOnInterrupt(enabled, {
  lastCallerTranscriptAt,
  lastCallerAudioAt,
  lastAiAudioAt,
  aiOutputActiveUntilMs,
  interruptionMode
} = {}) {
  if (!enabled) return false;

  const aiAudioTime = Date.parse(lastAiAudioAt || '');
  if (!Number.isFinite(aiAudioTime)) return false;
  if (!isAiOutputActive(aiOutputActiveUntilMs)) return false;

  if (normalizeInterruptionMode(interruptionMode) === 'provider') {
    const callerAudioTime = Date.parse(lastCallerAudioAt || '');
    return Number.isFinite(callerAudioTime) && callerAudioTime >= aiAudioTime;
  }

  const callerTime = Date.parse(lastCallerTranscriptAt || '');
  return Number.isFinite(callerTime) && callerTime >= aiAudioTime;
}

function shouldClearOutputBufferOnCallerTranscript(enabled, {
  callerTranscript,
  lastCallerTranscriptAt,
  lastAiAudioAt,
  aiOutputActiveUntilMs,
  lastConfirmedCallerInterruptAt
} = {}) {
  if (!meaningfulCallerTranscript(callerTranscript)) return false;
  if (lastConfirmedCallerInterruptAt && lastConfirmedCallerInterruptAt === lastCallerTranscriptAt) return false;
  return shouldClearOutputBufferOnInterrupt(enabled, { lastCallerTranscriptAt, lastAiAudioAt, aiOutputActiveUntilMs });
}

function isAiOutputActive(activeUntilMs) {
  const parsed = Number(activeUntilMs);
  return Number.isFinite(parsed) && parsed > Date.now();
}

function outputPlaybackDurationMs(outputPacer, data) {
  const bufferedBytes = Number(outputPacer?.buffer?.length || 0);
  const dataBytes = Buffer.isBuffer(data) ? data.length : Buffer.byteLength(Buffer.from(data || []));
  const bytes = Math.max(0, bufferedBytes + dataBytes);
  if (!bytes) return 0;
  return Math.max(20, Math.ceil((bytes / (FONOSTER_CALL_RATE * 2)) * 1000));
}

function meaningfulCallerTranscript(value) {
  const normalized = String(value || '').trim().toLowerCase();
  if (!normalized) return false;
  if (['да', 'нет', 'ок', 'ага', 'угу', 'алло'].includes(normalized)) return true;
  return /[\p{L}\p{N}]/u.test(normalized) && normalized.replace(/[^\p{L}\p{N}]+/gu, '').length >= 2;
}

function sanitizedInterruptTranscript(value) {
  return String(value || '').trim().replace(/\s+/g, ' ').slice(0, 160);
}

function normalizeInterruptionMode(value) {
  const normalized = String(value || '').trim().toLowerCase();
  return normalized === 'provider' || normalized === 'start_of_activity' ? 'provider' : 'transcript_confirmed';
}

function mediaStreamEstablishmentError(message, source = 'call.stream') {
  const error = new Error(sanitizeReason(message || 'media_stream_not_established'));
  error.code = 'media_stream_not_established';
  error.reason = 'media_stream_not_established';
  error.source = source;
  return error;
}

function isMediaStreamEstablishmentError(error) {
  return error?.code === 'media_stream_not_established' || error?.reason === 'media_stream_not_established';
}

function correlationPayload(session, requestPayload = {}, data = {}) {
  const source = data || {};
  return compactPayload({
    bridge_call_ref: session?.bridgeCallRef || bridgeCallRefCandidate(requestPayload) || bridgeCallRefCandidate(source),
    fonoster_call_ref: session?.callRef || requestPayload.call_ref || requestPayload.callRef,
    ai_runtime_call_ref: session?.callRef,
    runtime_call_ref: session?.callRef,
    conversation_id: source.conversation_id || source.conversationId || session?.context?.conversation_id || session?.context?.conversationId,
    conversation_display_id: source.conversation_display_id || source.conversationDisplayId,
    inbox_id: source.inbox_id || source.inboxId || requestPayload.inbox_id || requestPayload.inboxId,
    number_ref: session?.numberRef || source.number_ref || source.numberRef || requestPayload.number_ref || requestPayload.numberRef,
    ai_session_id: session?.aiSessionId,
    media_session_ref: session?.mediaSessionRef || source.media_session_ref || source.mediaSessionRef || requestPayload.media_session_ref || requestPayload.mediaSessionRef,
    stream_ref: session?.streamRef || source.stream_ref || source.streamRef || requestPayload.stream_ref || requestPayload.streamRef,
    provider: source.provider || source.ai?.provider || 'gemini-live',
    provider_session_id: source.provider_session_id || source.providerSessionId || session?.aiSessionId,
    app_ref: selectedAppRef(requestPayload, source),
    route_app_ref: routeAppRef(source),
    topology: directAiTopology(requestPayload, source),
    route_action: source.action || source.mode,
    route_reason: source.reason
  });
}

function selectedAppRef(requestPayload = {}, routeDecision = {}) {
  const inboundAppRef = requestAppRef(requestPayload);
  if (inboundAppRef && directAiTopology(requestPayload, routeDecision) === 'direct_ai') return inboundAppRef;

  return routeAppRef(routeDecision) || inboundAppRef;
}

function directAiTopology(requestPayload = {}, routeDecision = {}) {
  const inboundAppRef = requestAppRef(requestPayload);
  const routedAppRef = routeAppRef(routeDecision);
  const routeReason = String(routeDecision?.reason || '').trim().toLowerCase();
  if (inboundAppRef && routedAppRef && inboundAppRef === routedAppRef && normalizeRouteAction(routeDecision) === 'ai') return 'direct_ai';
  if (inboundAppRef && routedAppRef && inboundAppRef !== routedAppRef && routeReason === 'recursive_runtime_app_ref') return 'direct_ai';
  return undefined;
}

function routeAppRef(routeDecision = {}) {
  return routeDecision?.app_ref || routeDecision?.appRef;
}

function requestAppRef(requestPayload = {}) {
  return requestPayload?.app_ref || requestPayload?.appRef;
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
    bridge_call_ref: payload.bridge_call_ref || payload.bridgeCallRef || request.bridge_call_ref || request.bridgeCallRef ||
      payload.parent_call_ref || payload.parentCallRef || request.parent_call_ref || request.parentCallRef ||
      payload.original_call_ref || payload.originalCallRef || request.original_call_ref || request.originalCallRef,
    media_session_ref: payload.media_session_ref || payload.mediaSessionRef || request.media_session_ref || request.mediaSessionRef,
    ingress_number: payload.ingress_number || payload.to || request.ingress_number || request.to,
    caller_number: payload.caller_number || payload.from || request.caller_number || request.from
  };
}

function bridgeCallRefCandidate(payload = {}) {
  return payload.bridge_call_ref || payload.bridgeCallRef || payload.fonoster_bridge_call_ref || payload.fonosterBridgeCallRef ||
    payload.parent_call_ref || payload.parentCallRef || payload.original_call_ref || payload.originalCallRef;
}

function answerCall(call, { timeoutMs = 0 } = {}) {
  if (!call || typeof call.answer !== 'function') return Promise.resolve(false);
  return promiseWithTimeout(Promise.resolve(call.answer()).then(() => true), timeoutMs, 'app_answer_timeout', 'call.answer');
}

function promiseWithTimeout(promise, timeoutMs, reason, source) {
  if (!timeoutMs || timeoutMs <= 0) return promise;

  let timer;
  const timeout = new Promise((_, reject) => {
    timer = setTimeout(() => {
      const error = new Error(reason);
      error.reason = reason;
      error.source = source;
      error.timeoutMs = timeoutMs;
      reject(error);
    }, timeoutMs);
  });

  return Promise.race([promise, timeout]).finally(() => clearTimeout(timer));
}

function sanitizeReason(message) {
  return String(message || 'realtime_unavailable').replace(/(key|token|secret|password)=([^\s&]+)/gi, '$1=[REDACTED]');
}

function loadStreamConstants() {
  try {
    const common = require('@fonoster/common');
    return {
      audioIn: common.StreamMessageType?.AUDIO_IN || 'AUDIO_IN',
      audioOut: common.StreamMessageType?.AUDIO_OUT || 'AUDIO_OUT',
      wavFormat: common.StreamAudioFormat?.WAV || 'WAV',
      bothDirection: common.StreamDirection?.BOTH || 'BOTH'
    };
  } catch (_error) {
    return {
      audioIn: 'AUDIO_IN',
      audioOut: 'AUDIO_OUT',
      wavFormat: 'WAV',
      bothDirection: 'BOTH'
    };
  }
}

module.exports = { VoiceApplication, buildSystemPrompt, normalizeContextTools, normalizeCallPayload };
