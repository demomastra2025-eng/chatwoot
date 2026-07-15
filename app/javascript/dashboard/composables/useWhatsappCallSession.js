import { ref, computed, watch, onUnmounted } from 'vue';
import { useI18n } from 'vue-i18n';
import { useAlert } from 'dashboard/composables/useAlert';
import {
  useWhatsappCallsStore,
  getOutboundCallState,
  cleanupOutboundCall,
} from 'dashboard/stores/whatsappCalls';
import WhatsappCallsAPI from 'dashboard/api/whatsappCalls';
import Auth from 'dashboard/api/auth';
import Timer from 'dashboard/helper/Timer';
import { emitter } from 'shared/helpers/mitt';

// ── Module-level WebRTC state (shared across legacy inbound + server-relay) ──
let inboundPc = null;
let inboundStream = null;
let inboundAudio = null;
let inboundNegotiationToken = 0;

// Inbound accept can prewarm microphone while Rails/Meta accepts the call.
// Keep this separate from the active PeerConnection stream so a warmed inbound
// stream never leaks into the outbound server-relay path.
let inboundPrewarmStream = null;
let inboundPrewarmPromise = null;
let inboundPrewarmToken = 0;
const preparedInboundAgentAnswers = new Map();
const PREPARED_AGENT_ANSWER_TTL_MS = 15000;

// ── Module-level recording state (legacy mode only) ──
let mediaRecorder = null;
let recordedChunks = [];
let recordingCallId = null;

export const WHATSAPP_CALL_MEDIA_LEG_CLOSED_MESSAGE =
  'Звонок уже оборвался. Попробуйте перезвонить.';

export function isMediaLegClosedError(error) {
  const data = error?.response?.data;
  return (
    data?.code === 'media_leg_closed' ||
    data?.status === 'media_leg_closed' ||
    data?.error === 'media_leg_closed'
  );
}

function stopStream(stream) {
  stream?.getTracks?.().forEach(track => track.stop());
}

function inboundNegotiationCancelledError() {
  const error = new Error('Inbound WebRTC negotiation was cancelled');
  error.retryable = false;
  error.cancelled = true;
  error.stage = 'negotiation_cancelled';
  return error;
}

function assertInboundNegotiationActive(
  token,
  { stream = null, pc = null } = {}
) {
  if (token === inboundNegotiationToken) return;
  if (pc) pc.close();
  if (stream) stopStream(stream);
  throw inboundNegotiationCancelledError();
}

function cleanupInboundWebRTC({ keepPrewarmStream = false } = {}) {
  inboundNegotiationToken += 1;
  if (inboundPc) {
    inboundPc.close();
    inboundPc = null;
  }
  if (inboundStream) {
    stopStream(inboundStream);
    inboundStream = null;
  }
  if (!keepPrewarmStream) {
    inboundPrewarmToken += 1;
    inboundPrewarmPromise = null;
    if (inboundPrewarmStream) {
      stopStream(inboundPrewarmStream);
      inboundPrewarmStream = null;
    }
  }
  if (inboundAudio) {
    inboundAudio.srcObject = null;
    if (inboundAudio.parentNode) {
      inboundAudio.parentNode.removeChild(inboundAudio);
    }
    inboundAudio = null;
  }
}

function prepareInboundAudioStream() {
  if (inboundPrewarmStream) return Promise.resolve(inboundPrewarmStream);
  if (!inboundPrewarmPromise) {
    const token = inboundPrewarmToken;
    inboundPrewarmPromise = navigator.mediaDevices
      .getUserMedia({ audio: true })
      .then(stream => {
        if (token !== inboundPrewarmToken) {
          stopStream(stream);
          throw inboundNegotiationCancelledError();
        }
        inboundPrewarmStream = stream;
        return stream;
      })
      .catch(error => {
        if (token === inboundPrewarmToken) inboundPrewarmPromise = null;
        throw error;
      });
    inboundPrewarmPromise.catch(() => {});
  }
  return inboundPrewarmPromise;
}

async function takeInboundPrewarmedAudioStream() {
  if (!inboundPrewarmStream && !inboundPrewarmPromise) {
    return navigator.mediaDevices.getUserMedia({ audio: true });
  }
  const stream = inboundPrewarmStream || (await inboundPrewarmPromise);
  inboundPrewarmStream = null;
  inboundPrewarmPromise = null;
  inboundPrewarmToken += 1;
  return stream;
}

function isInboundDirection(direction) {
  return direction === 'incoming' || direction === 'inbound';
}

function preparedAnswerKeys(callLike = {}) {
  return [
    callLike.id ? `id:${callLike.id}` : null,
    callLike.callId ? `call:${callLike.callId}` : null,
    callLike.call_id ? `call:${callLike.call_id}` : null,
  ].filter(Boolean);
}

function setPreparedInboundAgentAnswer(callLike, record) {
  preparedAnswerKeys(callLike).forEach(key =>
    preparedInboundAgentAnswers.set(key, record)
  );
}

export function clearPreparedInboundAgentAnswer(
  callLike,
  { cleanupWebrtc = false } = {}
) {
  const records = new Set(
    preparedAnswerKeys(callLike)
      .map(key => preparedInboundAgentAnswers.get(key))
      .filter(Boolean)
  );
  preparedAnswerKeys(callLike).forEach(key =>
    preparedInboundAgentAnswers.delete(key)
  );
  if (records.size) {
    Array.from(preparedInboundAgentAnswers.entries()).forEach(
      ([key, record]) => {
        if (records.has(record)) preparedInboundAgentAnswers.delete(key);
      }
    );
  }
  if (cleanupWebrtc) cleanupInboundWebRTC();
}

function getPreparedInboundAgentAnswer(callLike) {
  const now = Date.now();
  const keys = preparedAnswerKeys(callLike);
  const record = keys
    .map(key => preparedInboundAgentAnswers.get(key))
    .find(Boolean);
  if (!record) return null;
  if (record.expiresAt <= now) {
    clearPreparedInboundAgentAnswer(callLike);
    return null;
  }
  return record;
}

function nowMs() {
  if (typeof performance !== 'undefined' && performance.now) {
    return Math.round(performance.now());
  }
  return Date.now();
}

const AGENT_WEBRTC_MAX_ATTEMPTS = 2;
const AGENT_WEBRTC_STEP_TIMEOUT_MS = 2500;
const AGENT_WEBRTC_MEDIA_TIMEOUT_MS = 15000;

function withTimeout(
  promise,
  timeoutMs,
  stage,
  { retryable = true, onLateResolve = null } = {}
) {
  let timeout = null;
  let timedOut = false;
  const guardedPromise = Promise.resolve(promise).then(value => {
    if (timedOut) onLateResolve?.(value);
    return value;
  });
  const timeoutPromise = new Promise((_, reject) => {
    timeout = setTimeout(() => {
      timedOut = true;
      const error = new Error(`${stage} timed out`);
      error.retryable = retryable;
      error.stage = stage;
      reject(error);
    }, timeoutMs);
  });

  return Promise.race([guardedPromise, timeoutPromise]).finally(() => {
    clearTimeout(timeout);
  });
}

function isRetryableAgentWebrtcError(error) {
  return error?.retryable === true;
}

function createCallTiming(callId, { direction, context }) {
  const startedAt = nowMs();
  const stages = {};
  const mark = stage => {
    stages[`${stage}_ms`] = nowMs() - startedAt;
    // eslint-disable-next-line no-console
    console.info('[WhatsApp Call][timing]', {
      callId,
      direction,
      context,
      stage,
      elapsedMs: stages[`${stage}_ms`],
    });
  };
  return { stages, mark };
}

export function handleMediaLegClosed(callsStore) {
  cleanupInboundWebRTC();
  callsStore?.clearActiveCall();
  callsStore?.setReconnecting(false);
  useAlert(WHATSAPP_CALL_MEDIA_LEG_CLOSED_MESSAGE);
}

/**
 * Start recording both local and remote audio tracks via MediaRecorder.
 * Mixes them into a single stream using AudioContext.
 * Used ONLY in legacy (browser-direct) mode.
 */
export function startCallRecording(pc, localStream, callId) {
  try {
    const ctx = new AudioContext();
    const dest = ctx.createMediaStreamDestination();

    if (localStream) {
      const localSource = ctx.createMediaStreamSource(localStream);
      localSource.connect(dest);
    }

    pc.getReceivers().forEach(receiver => {
      if (receiver.track && receiver.track.kind === 'audio') {
        const remoteStream = new MediaStream([receiver.track]);
        const remoteSource = ctx.createMediaStreamSource(remoteStream);
        remoteSource.connect(dest);
      }
    });

    recordedChunks = [];
    recordingCallId = callId;
    const recorder = new MediaRecorder(dest.stream, {
      mimeType: 'audio/webm;codecs=opus',
    });

    recorder.ondataavailable = e => {
      if (e.data.size > 0) recordedChunks.push(e.data);
    };

    mediaRecorder = recorder;
    recorder.start(1000);
  } catch (err) {
    // eslint-disable-next-line no-console
    console.error('[WhatsApp Call] Failed to start recording:', err);
  }
}

/**
 * Stop recording and upload the audio blob to the backend.
 * Used ONLY in legacy (browser-direct) mode.
 */
function stopAndUploadRecording(callId) {
  if (!mediaRecorder || mediaRecorder.state === 'inactive') return;

  const id = callId || recordingCallId;

  mediaRecorder.onstop = () => {
    if (recordedChunks.length === 0 || !id) return;

    const blob = new Blob(recordedChunks, { type: 'audio/webm' });
    recordedChunks = [];
    recordingCallId = null;

    WhatsappCallsAPI.uploadRecording(id, blob).catch(err => {
      // eslint-disable-next-line no-console
      console.error('[WhatsApp Call] Failed to upload recording:', err);
    });
  };

  mediaRecorder.stop();
  mediaRecorder = null;
}

function waitForIceGathering(
  pc,
  { timeoutMs, firstCandidate = false, warning }
) {
  return new Promise((resolve, reject) => {
    if (pc.iceGatheringState === 'complete') {
      resolve();
      return;
    }

    let timeout = null;

    const cleanup = () => {
      clearTimeout(timeout);
      pc.onicegatheringstatechange = null;
      pc.onicecandidate = null;
      pc.oniceconnectionstatechange = null;
    };

    timeout = setTimeout(() => {
      cleanup();
      // eslint-disable-next-line no-console
      console.warn(warning);
      resolve();
    }, timeoutMs);

    pc.onicegatheringstatechange = () => {
      if (pc.iceGatheringState === 'complete') {
        cleanup();
        resolve();
      }
    };
    pc.onicecandidate = event => {
      if (firstCandidate && event.candidate) {
        cleanup();
        resolve();
      }
    };
    pc.oniceconnectionstatechange = () => {
      if (pc.iceConnectionState === 'failed') {
        cleanup();
        const error = new Error('ICE connection failed');
        error.retryable = true;
        error.stage = 'ice_connection';
        reject(error);
      }
    };
  });
}

function waitForFastAgentAnswerSdp(pc) {
  return waitForIceGathering(pc, {
    timeoutMs: 750,
    firstCandidate: true,
    warning:
      '[WhatsApp Call] ICE gathering still running, sending fast partial SDP',
  });
}

function waitForIceGatheringComplete(pc) {
  return waitForIceGathering(pc, {
    timeoutMs: 10000,
    warning: '[WhatsApp Call] ICE gathering timed out, sending partial SDP',
  });
}

// ── Server-relay mode detection ──
// Prefer the explicit flag set by Rails whenever it's available (call object
// from GET /whatsapp_calls/:id, inbox serializer, or the incoming ActionCable
// broadcast). Fall back to the presence of sdpOffer so legacy deployments keep
// working when the field isn't set.
function isServerRelayCall(call) {
  if (call?.mediaServerEnabled === true) return true;
  if (call?.mediaServerEnabled === false) return false;
  return !call?.sdpOffer;
}

/**
 * Handle an SDP offer from the media server (Peer B). Used in server-relay mode
 * for both inbound accept and outbound connect flows.
 *
 * Flow: getUserMedia -> RTCPeerConnection(iceServers) -> setRemoteDescription(offer)
 *       -> createAnswer -> fast initial ICE wait -> POST /agent_answer
 */
async function negotiateAgentOfferOnce(
  callId,
  sdpOffer,
  iceServers,
  {
    direction,
    context,
    usePrewarmedStream,
    peerId,
    timing,
    deferPost = false,
    negotiationToken,
  }
) {
  timing.mark('get_user_media_start');
  const stream = usePrewarmedStream
    ? await withTimeout(
        takeInboundPrewarmedAudioStream(),
        AGENT_WEBRTC_MEDIA_TIMEOUT_MS,
        'get_user_media',
        { retryable: false, onLateResolve: stopStream }
      )
    : await withTimeout(
        navigator.mediaDevices.getUserMedia({ audio: true }),
        AGENT_WEBRTC_MEDIA_TIMEOUT_MS,
        'get_user_media',
        { retryable: false, onLateResolve: stopStream }
      );
  timing.mark('get_user_media_ok');
  assertInboundNegotiationActive(negotiationToken, { stream });
  inboundStream = stream;

  const servers = iceServers?.length
    ? iceServers
    : [{ urls: 'stun:stun.l.google.com:19302' }];

  const pc = new RTCPeerConnection({ iceServers: servers });
  assertInboundNegotiationActive(negotiationToken, { stream, pc });
  inboundPc = pc;

  // Keep the browser microphone as a real outbound WebRTC track. A previous
  // sendrecv-transceiver/replaceTrack variant made Chrome answer faster but in
  // production Pion never received the agent OnTrack callback, so the bridge
  // ended with agent_to_meta_packets=0. addTrack is the known working contract
  // for operator -> WhatsApp audio.
  stream.getTracks().forEach(track => pc.addTrack(track, stream));

  pc.ontrack = event => {
    const [remoteStream] = event.streams;
    if (!remoteStream) return;
    if (!inboundAudio) {
      const audio = document.createElement('audio');
      audio.autoplay = true;
      document.body.appendChild(audio);
      inboundAudio = audio;
    }
    inboundAudio.srcObject = remoteStream;
    inboundAudio.play().catch(() => {});

    // No client-side recording in server-relay mode — the media server records
  };

  await withTimeout(
    pc.setRemoteDescription({ type: 'offer', sdp: sdpOffer }),
    AGENT_WEBRTC_STEP_TIMEOUT_MS,
    'set_remote_description'
  );
  timing.mark('set_remote_description_ok');
  assertInboundNegotiationActive(negotiationToken, { stream, pc });
  const answer = await withTimeout(
    pc.createAnswer(),
    AGENT_WEBRTC_STEP_TIMEOUT_MS,
    'create_answer'
  );
  timing.mark('create_answer_ok');
  assertInboundNegotiationActive(negotiationToken, { stream, pc });
  await withTimeout(
    pc.setLocalDescription(answer),
    AGENT_WEBRTC_STEP_TIMEOUT_MS,
    'set_local_description'
  );
  timing.mark('set_local_description_ok');
  assertInboundNegotiationActive(negotiationToken, { stream, pc });
  await waitForFastAgentAnswerSdp(pc);
  timing.mark('fast_ice_ready');
  assertInboundNegotiationActive(negotiationToken, { stream, pc });

  const completeSdp = pc.localDescription.sdp;
  timing.mark('agent_answer_ready');

  const postAgentAnswer = async () => {
    assertInboundNegotiationActive(negotiationToken, { stream, pc });
    timing.mark('agent_answer_post_start');
    const clientTiming = {
      direction,
      context,
      stages: timing.stages,
    };
    if (peerId) {
      await WhatsappCallsAPI.agentAnswer(
        callId,
        completeSdp,
        clientTiming,
        peerId
      );
    } else {
      await WhatsappCallsAPI.agentAnswer(callId, completeSdp, clientTiming);
    }
    timing.mark('agent_answer_ok');
  };

  if (deferPost) {
    return { success: true, postAgentAnswer };
  }

  await postAgentAnswer();
  return { success: true };
}

async function handleAgentOffer(callId, sdpOffer, iceServers, options = {}) {
  const direction = options.direction || 'incoming';
  const context = options.context || 'agent-offer';
  const usePrewarmedStream =
    options.usePrewarmedStream === true && isInboundDirection(direction);
  const timing = createCallTiming(callId, { direction, context });
  timing.mark('offer_received');
  cleanupInboundWebRTC({ keepPrewarmStream: usePrewarmedStream });

  const attemptNegotiation = async attempt => {
    const negotiationToken = inboundNegotiationToken;
    try {
      return await negotiateAgentOfferOnce(callId, sdpOffer, iceServers, {
        direction,
        context,
        usePrewarmedStream: usePrewarmedStream && attempt === 1,
        peerId: options.peerId,
        timing,
        deferPost: options.deferPost === true,
        negotiationToken,
      });
    } catch (err) {
      if (!err.cancelled) cleanupInboundWebRTC();
      if (
        !err.cancelled &&
        attempt < AGENT_WEBRTC_MAX_ATTEMPTS &&
        isRetryableAgentWebrtcError(err)
      ) {
        // eslint-disable-next-line no-console
        console.warn(
          '[WhatsApp Call] Retrying agent WebRTC negotiation after local failure',
          { callId, direction, context, attempt, stage: err.stage }
        );
        return attemptNegotiation(attempt + 1);
      }
      timing.mark('agent_answer_error');
      throw err;
    }
  };

  return attemptNegotiation(1);
}

// Expose handleAgentOffer so ActionCable handler can invoke it
export { handleAgentOffer };

function prepareInboundAgentAnswer(callId, agentOffer) {
  if (!agentOffer?.sdp_offer) return null;
  return handleAgentOffer(
    callId,
    agentOffer.sdp_offer,
    agentOffer.ice_servers || [],
    {
      direction: 'incoming',
      context: 'pre-accept-agent-answer',
      usePrewarmedStream: true,
      peerId: agentOffer.peer_id,
      deferPost: true,
    }
  );
}

function sameAgentOffer(firstOffer, secondOffer) {
  if (!firstOffer?.sdp_offer || !secondOffer?.sdp_offer) return false;
  if (firstOffer.sdp_offer !== secondOffer.sdp_offer) return false;
  if ((firstOffer.peer_id || null) !== (secondOffer.peer_id || null)) {
    return false;
  }
  return (
    JSON.stringify(firstOffer.ice_servers || []) ===
    JSON.stringify(secondOffer.ice_servers || [])
  );
}

export function prewarmInboundAgentAnswerForCall(call) {
  if (!isServerRelayCall(call) || !call?.agentOffer?.sdp_offer) {
    if (isServerRelayCall(call)) prepareInboundAudioStream();
    return null;
  }

  prepareInboundAudioStream();
  const existing = getPreparedInboundAgentAnswer(call);
  if (existing && sameAgentOffer(existing.agentOffer, call.agentOffer)) {
    return existing.promise;
  }

  clearPreparedInboundAgentAnswer(call);
  const promise = prepareInboundAgentAnswer(call.id, call.agentOffer);
  const record = {
    agentOffer: call.agentOffer,
    promise,
    expiresAt: Date.now() + PREPARED_AGENT_ANSWER_TTL_MS,
  };
  setPreparedInboundAgentAnswer(call, record);
  promise.catch(() => clearPreparedInboundAgentAnswer(call));
  return promise;
}

function consumePreparedInboundAgentAnswer(call, agentOffer) {
  const record = getPreparedInboundAgentAnswer(call);
  if (!record || !sameAgentOffer(record.agentOffer, agentOffer)) return null;
  clearPreparedInboundAgentAnswer(call);
  return record.promise;
}

async function postPreparedInboundAgentAnswer(preparedAnswerPromise) {
  if (!preparedAnswerPromise) return false;
  const preparedAnswer = await preparedAnswerPromise;
  if (!preparedAnswer?.postAgentAnswer) return false;
  await preparedAnswer.postAgentAnswer();
  return true;
}

/**
 * Legacy mode: creates WebRTC session and posts SDP to backend (browser ↔ Meta).
 * Can be called from anywhere — composable, widget, or bubble.
 */
async function doAcceptCall(
  call,
  { preconnectedAgent = false, skipPrewarm = false } = {}
) {
  // Server-relay mode: POST /accept without SDP. New Rails returns the media
  // server's Peer-B offer in the response as the synchronous source of truth;
  // the ActionCable agent_offer event remains as a fallback for older tabs and
  // reconnects. The caller commits active-call state before attempting the local
  // browser WebRTC handshake, so a mic/ICE failure does not hide an already
  // accepted provider call from the agent UI.
  if (isServerRelayCall(call)) {
    if (!preconnectedAgent && !skipPrewarm) prepareInboundAudioStream();
    try {
      const { data } = await WhatsappCallsAPI.accept(call.id);
      return {
        success: true,
        awaitingAgentOffer: !data?.agent_offer?.sdp_offer,
        agentOffer: data?.agent_offer,
        acceptData: data,
      };
    } catch (error) {
      cleanupInboundWebRTC();
      throw error;
    }
  }

  // Legacy mode: full browser-side WebRTC handshake
  cleanupInboundWebRTC();

  try {
    const stream = await navigator.mediaDevices.getUserMedia({ audio: true });
    inboundStream = stream;

    const iceServers = call.iceServers?.length
      ? call.iceServers
      : [{ urls: 'stun:stun.l.google.com:19302' }];

    const pc = new RTCPeerConnection({ iceServers });
    inboundPc = pc;

    stream.getTracks().forEach(track => pc.addTrack(track, stream));

    pc.ontrack = event => {
      const [remoteStream] = event.streams;
      if (!remoteStream) return;
      if (!inboundAudio) {
        const audio = document.createElement('audio');
        audio.autoplay = true;
        document.body.appendChild(audio);
        inboundAudio = audio;
      }
      inboundAudio.srcObject = remoteStream;
      inboundAudio.play().catch(() => {});

      // Start recording once remote audio is available (legacy mode only)
      startCallRecording(pc, stream, call.id);
    };

    await pc.setRemoteDescription({ type: 'offer', sdp: call.sdpOffer });
    const answer = await pc.createAnswer();
    await pc.setLocalDescription(answer);
    await waitForIceGatheringComplete(pc);

    const completeSdp = pc.localDescription.sdp;
    await WhatsappCallsAPI.accept(call.id, completeSdp);

    return { success: true };
  } catch (err) {
    cleanupInboundWebRTC();
    throw err;
  }
}

async function connectAgentOfferForActiveCall(
  callsStore,
  callId,
  agentOffer,
  context,
  { usePrewarmedStream } = {}
) {
  if (!agentOffer?.sdp_offer) return false;

  try {
    callsStore.updateActiveCall({ agentWebrtcConnecting: true });
    await handleAgentOffer(
      callId,
      agentOffer.sdp_offer,
      agentOffer.ice_servers || [],
      {
        direction: callsStore.activeCall?.direction,
        context,
        usePrewarmedStream:
          usePrewarmedStream ??
          isInboundDirection(callsStore.activeCall?.direction),
        peerId: agentOffer.peer_id,
      }
    );
    callsStore.updateActiveCall({
      agentWebrtcConnected: true,
      agentWebrtcConnecting: false,
    });
    callsStore.markActiveCallConnected();
    callsStore.setReconnecting(false);
    emitter.emit('whatsapp_call:agent_webrtc_connected');
    return true;
  } catch (err) {
    callsStore.updateActiveCall({ agentWebrtcConnecting: false });
    callsStore.setReconnecting(false);
    if (isMediaLegClosedError(err)) {
      handleMediaLegClosed(callsStore);
      return false;
    }
    // The provider call is already accepted at this point. Keep the call active
    // so the agent can reconnect/retry instead of losing visibility in the UI.
    // eslint-disable-next-line no-console
    console.error(
      `[WhatsApp Call] Failed to handle ${context} agent offer:`,
      err
    );
    return false;
  }
}

async function connectPreparedOrFallbackAgentOffer({
  callsStore,
  activeCallData,
  preparedAnswerPromise,
  fallbackAgentOffer,
  forceFreshStream = false,
}) {
  if (preparedAnswerPromise) {
    try {
      callsStore.updateActiveCall({ agentWebrtcConnecting: true });
      await postPreparedInboundAgentAnswer(preparedAnswerPromise);
      callsStore.updateActiveCall({
        agentWebrtcConnected: true,
        agentWebrtcConnecting: false,
      });
      callsStore.markActiveCallConnected();
      callsStore.setReconnecting(false);
      emitter.emit('whatsapp_call:agent_webrtc_connected');
      return true;
    } catch (err) {
      callsStore.updateActiveCall({ agentWebrtcConnecting: false });
      callsStore.setReconnecting(false);
      if (isMediaLegClosedError(err)) {
        handleMediaLegClosed(callsStore);
        return false;
      }
      // Fallback to a fresh negotiation below. The provider call is already
      // accepted, so keep UI state visible and do not drop the call.
      // eslint-disable-next-line no-console
      console.warn(
        '[WhatsApp Call] Prepared inbound agent answer failed:',
        err
      );
    }
  }

  return connectAgentOfferForActiveCall(
    callsStore,
    activeCallData.id,
    fallbackAgentOffer,
    'accept-response',
    { usePrewarmedStream: !forceFreshStream }
  );
}

/**
 * Standalone function callable from VoiceCall bubble.
 * Fetches call data if needed, runs WebRTC accept, updates store.
 */
export async function acceptWhatsappCallById(callId) {
  const callsStore = useWhatsappCallsStore();

  if (callsStore.hasActiveCall) {
    return { success: false, error: 'active_call_exists' };
  }

  let call = callsStore.incomingCalls.find(
    c => c.id === callId || c.callId === String(callId)
  );

  if (!call) {
    const { data } = await WhatsappCallsAPI.show(callId);
    if (data.status !== 'ringing') {
      return { success: false, error: 'not_ringing' };
    }
    call = {
      id: data.id,
      callId: data.call_id,
      direction: data.direction,
      inboxId: data.inbox_id,
      conversationId: data.conversation_id,
      conversationDisplayId: data.conversation_display_id,
      sdpOffer: data.sdp_offer,
      iceServers: data.ice_servers,
      mediaServerEnabled: data.media_server_enabled,
      mediaSessionId: data.media_session_id,
      agentOffer: data.agent_offer || null,
      caller: data.caller,
    };
    callsStore.addIncomingCall(call);
  }

  let serverRelay = false;
  let preparedAgentAnswerPromise = null;
  let preparedAgentOffer = null;

  try {
    serverRelay = isServerRelayCall(call);
    const preconnectedAgent = false;

    if (serverRelay) {
      // Inbound Meta calls have a short accept window. Start browser-side
      // negotiation immediately when an agent offer is already available, but
      // keep /agent_answer gated until provider /accept succeeds.
      const activeCallData = {
        ...call,
        serverRelay: true,
        agentWebrtcConnected: false,
        agentWebrtcConnecting: false,
        providerAccepting: true,
        status: call.status || 'ringing',
      };
      callsStore.setActiveCall(activeCallData);
      prepareInboundAudioStream();
      preparedAgentOffer =
        call.agentOffer || callsStore.consumePendingAgentOffer(activeCallData);
      preparedAgentAnswerPromise =
        consumePreparedInboundAgentAnswer(call, preparedAgentOffer) ||
        prepareInboundAgentAnswer(call.id, preparedAgentOffer);
      preparedAgentAnswerPromise?.catch(() => {});
    }

    const result = await doAcceptCall(call, {
      preconnectedAgent,
      skipPrewarm: preparedAgentAnswerPromise !== null,
    });

    callsStore.removeIncomingCall(call.callId);

    // In server-relay mode the call becomes active but awaits the agent_offer
    // ActionCable event to complete WebRTC setup. Mark it with serverRelay flag.
    const existingActiveCall = callsStore.activeCall;
    const activeCallData = {
      ...call,
      conversationId: result.acceptData?.conversation_id || call.conversationId,
      conversationDisplayId:
        result.acceptData?.conversation_display_id ||
        call.conversationDisplayId,
      communicationThreadId:
        result.acceptData?.communication_thread_id ||
        result.acceptData?.communicationThreadId ||
        call.communicationThreadId ||
        call.communication_thread_id,
      serverRelay,
      agentWebrtcConnected: preconnectedAgent,
      agentWebrtcConnecting: false,
      providerAccepting: false,
      status:
        preconnectedAgent && existingActiveCall?.status === 'connected'
          ? 'connected'
          : result.acceptData?.status || call.status,
    };
    callsStore.setActiveCall(activeCallData);
    const freshOfferReplacesPrepared = Boolean(
      preparedAgentOffer &&
        result.agentOffer &&
        !sameAgentOffer(result.agentOffer, preparedAgentOffer)
    );
    const preparedAnswerPromiseForConnect = freshOfferReplacesPrepared
      ? null
      : preparedAgentAnswerPromise;
    if (!preparedAnswerPromiseForConnect) {
      preparedAgentAnswerPromise?.catch(() => {});
      if (freshOfferReplacesPrepared) cleanupInboundWebRTC();
    }
    const fallbackAgentOffer =
      result.agentOffer ||
      preparedAgentOffer ||
      call.agentOffer ||
      callsStore.consumePendingAgentOffer(activeCallData);
    if (result.agentOffer) callsStore.clearPendingAgentOffer(activeCallData);
    await connectPreparedOrFallbackAgentOffer({
      callsStore,
      activeCallData,
      preparedAnswerPromise: preparedAnswerPromiseForConnect,
      fallbackAgentOffer,
      forceFreshStream: freshOfferReplacesPrepared,
    });

    return { success: true, call: callsStore.activeCall, ...result };
  } catch (err) {
    preparedAgentAnswerPromise?.catch(() => {});
    if (serverRelay) callsStore.clearActiveCall();
    cleanupInboundWebRTC();
    callsStore.removeIncomingCall(call.callId);
    throw err;
  }
}

/**
 * Fire-and-forget terminate request using fetch + keepalive.
 * Works reliably inside beforeunload / pagehide where axios won't complete.
 * Used ONLY in legacy mode. Server-relay mode does NOT terminate on unload.
 */
function terminateCallOnUnload(callId) {
  const authData = Auth.hasAuthCookie() ? Auth.getAuthData() : {};
  const accountId =
    window.location.pathname.includes('/app/accounts') &&
    window.location.pathname.split('/')[3];
  if (!accountId) return;

  const url = `/api/v1/accounts/${accountId}/whatsapp_calls/${callId}/terminate`;
  fetch(url, {
    method: 'POST',
    keepalive: true,
    headers: {
      'Content-Type': 'application/json',
      'access-token': authData['access-token'] || '',
      'token-type': authData['token-type'] || '',
      client: authData.client || '',
      expiry: authData.expiry || '',
      uid: authData.uid || '',
    },
  }).catch(() => {});
}

// ── Composable (used by WhatsappCallWidget for floating UI + timer) ──
export function useWhatsappCallSession() {
  const { t } = useI18n();
  const callsStore = useWhatsappCallsStore();

  const isAccepting = computed(() => callsStore.isAccepting);
  const isMuted = ref(false);
  const callError = ref(null);
  const callDuration = ref(0);
  const isReconnecting = computed(() => callsStore.isReconnecting);

  const durationTimer = new Timer(elapsed => {
    callDuration.value = callsStore.callTimerOffset + elapsed;
  });

  const activeCall = computed(() => callsStore.activeCall);
  const incomingCalls = computed(() => callsStore.incomingCalls);
  const hasActiveCall = computed(() => callsStore.hasActiveCall);
  const hasIncomingCall = computed(() => callsStore.hasIncomingCall);
  const firstIncomingCall = computed(() => callsStore.firstIncomingCall);

  const isOutboundRinging = computed(
    () =>
      activeCall.value?.direction === 'outbound' &&
      activeCall.value?.status === 'ringing'
  );

  const formattedCallDuration = computed(() => {
    const minutes = Math.floor(callDuration.value / 60);
    const seconds = callDuration.value % 60;
    return `${minutes.toString().padStart(2, '0')}:${seconds.toString().padStart(2, '0')}`;
  });

  // Register cleanup so external call-end events can teardown WebRTC
  callsStore.registerCleanupCallback(() => {
    // Only do recording cleanup in legacy mode
    if (!callsStore.isMediaServerEnabled) {
      stopAndUploadRecording();
    }
    cleanupInboundWebRTC();
    durationTimer.stop();
    callDuration.value = 0;
  });

  // On page close / reload:
  // - Legacy mode: terminate call (current behavior)
  // - Server-relay mode: just clean up local WebRTC resources, call persists
  const handleBeforeUnload = () => {
    const call = callsStore.activeCall;
    if (!call?.id) return;

    if (call.serverRelay) {
      // Server-relay: only clean up local resources, do NOT terminate
      cleanupInboundWebRTC();
    } else {
      // Legacy: terminate and clean up
      terminateCallOnUnload(call.id);
      cleanupInboundWebRTC();
    }
  };
  window.addEventListener('beforeunload', handleBeforeUnload);

  // Start timer when outbound call becomes connected
  watch(activeCall, call => {
    if (
      call?.direction === 'outbound' &&
      call?.status === 'connected' &&
      !durationTimer.intervalId
    ) {
      durationTimer.start();
    }
  });

  /**
   * Accept an incoming call — used by the floating widget buttons.
   */
  const acceptCall = async call => {
    if (callsStore.isAccepting) return;
    callsStore.setAccepting(true);
    callError.value = null;

    let serverRelay = false;
    let preparedAgentAnswerPromise = null;
    let preparedAgentOffer = null;

    try {
      serverRelay = isServerRelayCall(call);
      const preconnectedAgent = false;

      if (serverRelay) {
        // Inbound Meta calls have a short accept window. Start browser-side
        // negotiation immediately when an agent offer is already available, but
        // keep /agent_answer gated until provider /accept succeeds.
        const activeCallData = {
          ...call,
          serverRelay: true,
          agentWebrtcConnected: false,
          agentWebrtcConnecting: false,
          providerAccepting: true,
          status: call.status || 'ringing',
        };
        callsStore.setActiveCall(activeCallData);
        prepareInboundAudioStream();
        preparedAgentOffer =
          call.agentOffer ||
          callsStore.consumePendingAgentOffer(activeCallData);
        preparedAgentAnswerPromise =
          consumePreparedInboundAgentAnswer(call, preparedAgentOffer) ||
          prepareInboundAgentAnswer(call.id, preparedAgentOffer);
        preparedAgentAnswerPromise?.catch(() => {});
      }

      const result = await doAcceptCall(call, {
        preconnectedAgent,
        skipPrewarm: preparedAgentAnswerPromise !== null,
      });
      callsStore.removeIncomingCall(call.callId);

      const existingActiveCall = callsStore.activeCall;
      const activeCallData = {
        ...call,
        conversationId:
          result.acceptData?.conversation_id || call.conversationId,
        conversationDisplayId:
          result.acceptData?.conversation_display_id ||
          call.conversationDisplayId,
        serverRelay,
        agentWebrtcConnected: preconnectedAgent,
        agentWebrtcConnecting: false,
        providerAccepting: false,
        status:
          preconnectedAgent && existingActiveCall?.status === 'connected'
            ? 'connected'
            : result.acceptData?.status || call.status,
      };
      callsStore.setActiveCall(activeCallData);
      const freshOfferReplacesPrepared = Boolean(
        preparedAgentOffer &&
          result.agentOffer &&
          !sameAgentOffer(result.agentOffer, preparedAgentOffer)
      );
      const preparedAnswerPromiseForConnect = freshOfferReplacesPrepared
        ? null
        : preparedAgentAnswerPromise;
      if (!preparedAnswerPromiseForConnect) {
        preparedAgentAnswerPromise?.catch(() => {});
        if (freshOfferReplacesPrepared) cleanupInboundWebRTC();
      }
      const fallbackAgentOffer =
        result.agentOffer ||
        preparedAgentOffer ||
        call.agentOffer ||
        callsStore.consumePendingAgentOffer(activeCallData);
      if (result.agentOffer) callsStore.clearPendingAgentOffer(activeCallData);
      await connectPreparedOrFallbackAgentOffer({
        callsStore,
        activeCallData,
        preparedAnswerPromise: preparedAnswerPromiseForConnect,
        fallbackAgentOffer,
        forceFreshStream: freshOfferReplacesPrepared,
      });

      // In legacy mode, WebRTC is already established so start timer now.
      // In server-relay mode, timer starts when handleAgentOffer completes
      // (triggered by the whatsapp_call.agent_offer ActionCable event).
      if (!activeCallData.serverRelay) {
        durationTimer.start();
      }
    } catch (err) {
      if (serverRelay) callsStore.clearActiveCall();
      preparedAgentAnswerPromise?.catch(() => {});
      cleanupInboundWebRTC();
      callError.value =
        err.name === 'NotAllowedError'
          ? t('WHATSAPP_CALL.MIC_DENIED')
          : t('WHATSAPP_CALL.CALL_FAILED');
      // eslint-disable-next-line no-console
      console.error('[WhatsApp Call] acceptCall error:', err);
      // Note: doAcceptCall already cleans up WebRTC resources on error
    } finally {
      callsStore.setAccepting(false);
    }
  };

  const rejectCall = async call => {
    try {
      await WhatsappCallsAPI.reject(call.id);
    } catch {
      // Best effort
    } finally {
      callsStore.removeIncomingCall(call.callId);
    }
  };

  const endActiveCall = async () => {
    const call = activeCall.value;
    if (!call) return;

    // Only upload recording in legacy mode
    if (!call.serverRelay) {
      stopAndUploadRecording(call.id);
    }

    try {
      await WhatsappCallsAPI.terminate(call.id);
    } catch {
      // Best effort
    } finally {
      cleanupInboundWebRTC();
      cleanupOutboundCall();
      // Clear state directly — do NOT use handleCallEnded here since that is
      // meant for external events (ActionCable) and would invoke cleanupCallback
      // which would duplicate the cleanup we just performed.
      callsStore.clearActiveCall();
      durationTimer.stop();
      callDuration.value = 0;
    }
  };

  const toggleMute = () => {
    const stream = inboundStream || getOutboundCallState().stream;
    if (!stream) return;
    const audioTrack = stream.getAudioTracks()[0];
    if (!audioTrack) return;
    audioTrack.enabled = !audioTrack.enabled;
    isMuted.value = !audioTrack.enabled;
  };

  const dismissIncomingCall = call => {
    callsStore.removeIncomingCall(call.callId);
  };

  /**
   * Start the duration timer. Called externally after server-relay WebRTC
   * setup completes (handleAgentOffer).
   */
  const startDurationTimer = () => {
    durationTimer.start();
  };

  onUnmounted(() => {
    window.removeEventListener('beforeunload', handleBeforeUnload);
    durationTimer.stop();
  });

  return {
    activeCall,
    incomingCalls,
    hasActiveCall,
    hasIncomingCall,
    firstIncomingCall,
    isAccepting,
    isMuted,
    isOutboundRinging,
    isReconnecting,
    callError,
    formattedCallDuration,
    acceptCall,
    rejectCall,
    endActiveCall,
    toggleMute,
    dismissIncomingCall,
    startDurationTimer,
  };
}
