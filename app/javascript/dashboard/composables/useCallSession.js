import { computed, ref, watch, onUnmounted, onMounted } from 'vue';
import { useRoute } from 'vue-router';
import { useStore } from 'vuex';
import VoiceAPI from 'dashboard/api/channel/voice/voiceAPIClient';
import WebphoneClient from 'dashboard/api/channel/voice/webphoneClient';
import { useCallsStore } from 'dashboard/stores/calls';
import { INBOX_TYPES } from 'dashboard/helper/inbox';
import { isCommunicationThread } from 'dashboard/helper/communicationThreadHelper';
import Timer from 'dashboard/helper/Timer';
import { BUS_EVENTS } from 'shared/constants/busEvents';
import { emitter } from 'shared/helpers/mitt';

const INCOMING_BOOTSTRAP_RETRY_MS = 10_000;
const INCOMING_BOOTSTRAP_REFRESH_MS = 300_000;
const TERMINAL_CLAIM_FAILURE_CODES = new Set(['CALL_NOT_CLAIMABLE']);
const TERMINAL_CLAIM_FAILURE_STATUSES = new Set([
  'completed',
  'busy',
  'failed',
  'no_answer',
  'no-answer',
  'cancelled',
  'canceled',
  'rejected',
  'missed',
  'ended',
]);
const RETRYABLE_CLAIM_FAILURE_REASONS = new Set([
  'sipuni_operator_leg_not_ready',
]);
const BROWSER_CALLING_PROVIDERS = new Set([
  'asterisk_analog',
  'sipuni',
  'binotel',
  'twilio',
]);
const NATIVE_BROWSER_SIP_PROVIDERS = new Set([
  'asterisk_analog',
  'sipuni',
  'binotel',
]);
const JANUS_NATIVE_BROWSER_SIP_PROVIDERS = new Set([
  'asterisk_analog',
  'sipuni',
  'binotel',
]);
const BROWSER_SIP_INCOMING_REPORT_PROVIDERS = new Set([
  'asterisk_analog',
  'binotel',
  'sipuni',
]);
const STALE_BROWSER_SIP_INCOMING_STATUSES = new Set([404, 422]);

const positiveNumber = value => {
  const numericValue = Number(value);
  return Number.isFinite(numericValue) && numericValue > 0
    ? numericValue
    : null;
};

const isBrowserCallingInbox = inbox => {
  if (!inbox) return false;

  const provider = (inbox.provider || inbox.channel?.provider)
    ?.toString()
    .toLowerCase();
  if (BROWSER_CALLING_PROVIDERS.has(provider)) return true;

  const channelType =
    inbox.channel_type ||
    inbox.channelType ||
    inbox.channel?.channel_type ||
    inbox.channel?.channelType ||
    inbox.channel;
  return channelType === INBOX_TYPES.VOICE;
};

const isVoiceChannel = channel => {
  const channelType =
    channel?.channel ||
    channel?.channel_type ||
    channel?.channelType ||
    channel;
  return channelType === INBOX_TYPES.VOICE;
};

export function useCallSession() {
  const callsStore = useCallsStore();
  const route = useRoute();
  const store = useStore();
  const isJoining = ref(false);
  const pendingWebphoneConfigRefresh = ref(null);
  const isRefreshingWebphoneConfig = ref(false);
  const endingCallSids = ref(new Set());
  const releasingCallSids = ref(new Set());
  let bootstrapRetryTimer = null;
  let bootstrapRefreshTimer = null;
  let bootstrapIncomingPromise = null;
  let activeBootstrapInboxId;
  let pendingBootstrapInboxId;
  let deferredBootstrapInboxId;
  let webphoneConfigRefreshVersion = 0;
  const callDuration = ref(0);
  const durationTimer = new Timer(elapsed => {
    callDuration.value = elapsed;
  });

  const activeCall = computed(() => callsStore.activeCall);
  const incomingCalls = computed(() => callsStore.incomingCalls);
  const hasActiveCall = computed(() => callsStore.hasActiveCall);
  const resolveCallProvider = call => call?.provider || null;
  const sipProfileIdForCall = call =>
    call?.sipProfileId ||
    call?.sip_profile_id ||
    call?.operatorClaim?.sip_profile_id ||
    call?.operatorClaim?.sipProfileId ||
    call?.operatorCandidates?.[0]?.sip_profile_id ||
    call?.operatorCandidates?.[0]?.sipProfileId;
  const webphoneCallScope = call => ({
    provider: resolveCallProvider(call),
    inboxId: call?.inboxId || call?.inbox_id,
    callRef: call?.callRef || call?.callSid || call?.call_sid || call?.call_ref,
    sipProfileId: sipProfileIdForCall(call),
    sessionKey:
      call?.sessionKey ||
      call?.session_key ||
      call?.janusSessionKey ||
      call?.janus_session_key,
  });
  const routeActionForCall = call =>
    (
      call?.route_action ||
      call?.routeAction ||
      call?.metadata?.route_action ||
      call?.metadata?.routeAction ||
      ''
    )
      .toString()
      .trim()
      .toLowerCase();
  const isAiVoiceCall = call =>
    Boolean(
      call?.ai_voice ||
        call?.aiVoice ||
        call?.aiBridge ||
        call?.callMode === 'ai' ||
        routeActionForCall(call) === 'ai'
    );
  const janusCallRefForCall = call =>
    call?.janusCallRef ||
    call?.janus_call_ref ||
    call?.metadata?.janus_call_ref ||
    call?.operatorClaim?.janus_call_ref ||
    call?.operatorClaim?.janusCallRef;
  const janusWebphoneCallScope = call => ({
    ...webphoneCallScope(call),
    janusCallRef: janusCallRefForCall(call),
  });
  const trackedCallForSid = (callSid, scope = {}) => {
    const scopeValueMatches = (actual, expected) =>
      expected === undefined ||
      expected === null ||
      expected === '' ||
      actual === undefined ||
      actual === null ||
      actual === '' ||
      String(actual) === String(expected);
    const candidates = callsStore.calls.filter(call => {
      return (
        String(call.callSid) === String(callSid) &&
        scopeValueMatches(call.provider, scope.provider) &&
        scopeValueMatches(
          call.janusSessionKey || call.janus_session_key || call.sessionKey,
          scope.sessionKey || scope.session_key
        ) &&
        scopeValueMatches(
          sipProfileIdForCall(call),
          scope.sipProfileId || scope.sip_profile_id
        ) &&
        scopeValueMatches(
          call.inboxId || call.inbox_id,
          scope.inboxId || scope.inbox_id
        )
      );
    });
    return candidates.length === 1 ? candidates[0] : null;
  };
  const isOutboundCallDirection = callDirection => callDirection === 'outbound';
  const routeInboxId = computed(() => {
    const value = route.params?.inbox_id || route.params?.inboxId;
    return positiveNumber(value);
  });
  const routeCommunicationThreadId = computed(() => {
    const value =
      route.params?.communication_thread_id ||
      route.params?.communicationThreadId;
    return positiveNumber(value);
  });
  const routeVoiceInboxId = computed(() => {
    const inboxId = routeInboxId.value;
    if (!inboxId) return null;

    const inbox = store.getters?.['inboxes/getInbox']?.(inboxId);
    return isBrowserCallingInbox(inbox) ? inboxId : null;
  });
  const routeCommunicationThread = computed(() => {
    const threadId = routeCommunicationThreadId.value;
    if (!threadId) return null;

    const selectedChat = store.getters?.getSelectedChat;
    if (
      String(selectedChat?.id) === String(threadId) &&
      isCommunicationThread(selectedChat)
    ) {
      return selectedChat;
    }

    const conversationById = store.getters?.getConversationById;
    if (typeof conversationById !== 'function') return null;

    const communicationThread = conversationById(
      threadId,
      'communication_thread'
    );
    return isCommunicationThread(communicationThread)
      ? communicationThread
      : null;
  });
  const routeCommunicationThreadVoiceInboxId = computed(() => {
    const thread = routeCommunicationThread.value;
    if (!thread) return null;

    const activeChannel = thread.active_reply_channel;
    const activeChannelInboxId = positiveNumber(
      activeChannel?.inbox_id || thread.active_reply_channel_inbox_id
    );
    if (activeChannelInboxId && isVoiceChannel(activeChannel)) {
      return activeChannelInboxId;
    }

    const voiceChannel = (
      Array.isArray(thread.channels) ? thread.channels : []
    ).find(
      channel => positiveNumber(channel?.inbox_id) && isVoiceChannel(channel)
    );
    if (voiceChannel) return positiveNumber(voiceChannel.inbox_id);

    const inboxId = positiveNumber(thread.inbox_id);
    if (!inboxId) return null;

    const inbox = store.getters?.['inboxes/getInbox']?.(inboxId);
    return isBrowserCallingInbox(inbox) ? inboxId : null;
  });
  const incomingVoiceInboxId = computed(() => {
    const call = incomingCalls.value.find(item => {
      return (
        ['asterisk_analog', 'sipuni', 'binotel', 'twilio'].includes(
          item?.provider
        ) &&
        Number.isFinite(Number(item?.inboxId)) &&
        Number(item.inboxId) > 0
      );
    });

    return call ? Number(call.inboxId) : null;
  });
  const browserSipProviderForInboxId = inboxId => {
    const inbox = store.getters?.['inboxes/getInbox']?.(inboxId);
    const provider = (inbox?.provider || inbox?.channel?.provider)
      ?.toString()
      .toLowerCase();
    return NATIVE_BROWSER_SIP_PROVIDERS.has(provider) ? provider : null;
  };
  const incomingCallProviderForInboxId = inboxId => {
    const call = incomingCalls.value.find(item => {
      return String(item?.inboxId) === String(inboxId);
    });
    return call?.provider || null;
  };
  const shouldUseNativeWebphoneToken = ({ inboxId, provider }) => {
    return (
      NATIVE_BROWSER_SIP_PROVIDERS.has(provider) ||
      Boolean(browserSipProviderForInboxId(inboxId))
    );
  };
  const initializeWebphoneDevice = (
    inboxId,
    { provider = null, sipProfileId = null, sessionKey = null } = {}
  ) => {
    const native = shouldUseNativeWebphoneToken({ inboxId, provider });
    const options = { native };
    if (provider) options.provider = provider;
    if (sipProfileId) options.sipProfileId = sipProfileId;
    if (sessionKey) options.sessionKey = sessionKey;
    return native || provider || sipProfileId || sessionKey
      ? WebphoneClient.initializeDevice(inboxId, options)
      : WebphoneClient.initializeDevice(inboxId);
  };

  watch(
    hasActiveCall,
    active => {
      if (active) {
        durationTimer.start();
      } else {
        durationTimer.stop();
        callDuration.value = 0;
      }
    },
    { immediate: true }
  );

  const claimErrorPayload = error => error?.response?.data || {};

  const operatorClaimFromDetails = details => {
    if (!details || typeof details !== 'object') return null;

    const operatorClaim = {
      agent_binding_id: details.agent_binding_id,
      sip_profile_id: details.sip_profile_id,
      agent_ref: details.agent_ref,
      agent_aor: details.agent_aor,
      user_id: details.user_id,
      user_name: details.user_name || details.name,
    };

    return Object.values(operatorClaim).some(Boolean) ? operatorClaim : null;
  };

  const shouldDismissClaimFailure = claimResult => {
    if (TERMINAL_CLAIM_FAILURE_CODES.has(claimResult?.code)) return true;

    const status = claimResult?.details?.status;
    const normalizedStatus = status?.toString().trim().toLowerCase();
    return TERMINAL_CLAIM_FAILURE_STATUSES.has(normalizedStatus);
  };

  const shouldRetryClaimFailure = claimResult => {
    const reason = claimResult?.reason || claimResult?.code;
    return RETRYABLE_CLAIM_FAILURE_REASONS.has(reason);
  };

  const claimBrowserSipIncomingCall = async callSid => {
    try {
      const payload = await VoiceAPI.claimIncomingCall(callSid);
      return {
        ...payload,
        claimed: true,
        communicationThreadId:
          payload?.communication_thread_id || payload?.communicationThreadId,
      };
    } catch (error) {
      const payload = claimErrorPayload(error);
      // eslint-disable-next-line no-console
      console.warn('Failed to claim incoming call:', error);
      return {
        claimed: false,
        code: payload.code,
        reason: payload.details?.reason,
        details: payload.details,
      };
    }
  };

  const releaseBrowserSipCall = async (
    callSid,
    { status = 'rejected', reason = 'operator_declined', endedAt = null } = {}
  ) => {
    if (!callSid) return null;

    try {
      return await VoiceAPI.rejectIncomingCall(callSid, {
        status,
        reason,
        ...(endedAt ? { ended_at: endedAt } : {}),
      });
    } catch (error) {
      // eslint-disable-next-line no-console
      console.warn('Failed to release incoming call:', error);
      return null;
    }
  };

  const releaseUnsupportedBrowserSipJoin = async (
    callSid,
    { includeReason = false, provider, scope = {} } = {}
  ) => {
    await releaseBrowserSipCall(callSid, {
      status: 'no_answer',
      reason: 'browser_webphone_not_ready',
    });
    callsStore.markBrowserJoinUnsupported(callSid, provider, {}, scope);
    callsStore.dismissCall(callSid, provider, scope);
    return {
      provider,
      joinSupported: false,
      ...(includeReason ? { reason: 'browser_webphone_not_ready' } : {}),
    };
  };

  const releaseClaimedNativeBrowserSipCallWithoutInvite = async (
    callSid,
    { provider, communicationThreadId = null, scope = {} } = {}
  ) => {
    const releaseResult = await releaseBrowserSipCall(callSid, {
      status: 'no_answer',
      reason: 'sip_invite_not_received',
    });
    callsStore.markBrowserJoinUnsupported(
      callSid,
      provider,
      { reason: 'sip_invite_not_received' },
      scope
    );
    if (releaseResult) {
      callsStore.dismissCall(callSid, provider, scope);
    }

    return {
      provider,
      joinSupported: false,
      reason: 'sip_invite_not_received',
      ...(communicationThreadId ? { communicationThreadId } : {}),
    };
  };

  const failNativeBrowserSipCallWithoutInvite = (
    callSid,
    { provider, communicationThreadId = null, scope = {} } = {}
  ) => {
    callsStore.markBrowserJoinUnsupported(
      callSid,
      provider,
      { reason: 'sip_invite_not_received' },
      scope
    );

    return {
      provider,
      joinSupported: false,
      reason: 'sip_invite_not_received',
      ...(communicationThreadId ? { communicationThreadId } : {}),
    };
  };

  const failNativeOutboundStart = async (
    callSid,
    { provider, error = null, scope = {} } = {}
  ) => {
    const reason =
      error?.reason ||
      (error?.sipCallSent
        ? 'sip_outbound_start_failed'
        : 'sip_invite_not_received');
    await releaseBrowserSipCall(callSid, {
      status: 'failed',
      reason,
    });
    callsStore.dismissCall(callSid, provider, scope);
    return {
      provider,
      joinSupported: false,
      reason,
      callSid,
    };
  };

  const unknownCallReleaseKey = Symbol('unknown_call');
  const callReleaseKey = (callSid, scope = null) => {
    if (!callSid) return unknownCallReleaseKey;
    const provider = typeof scope === 'object' ? scope?.provider : scope;
    const sessionScope =
      typeof scope === 'object'
        ? scope?.janusSessionKey ||
          scope?.janus_session_key ||
          scope?.sessionKey ||
          scope?.session_key ||
          sipProfileIdForCall(scope) ||
          scope?.inboxId ||
          scope?.inbox_id
        : null;
    return `${provider || 'unknown'}:${sessionScope || 'unscoped'}:${callSid}`;
  };
  const hasTrackedCall = (callSid, scope = {}) =>
    Boolean(trackedCallForSid(callSid, scope));

  const runOnceForCall = async (
    lockSetRef,
    callSid,
    callback,
    scope = null
  ) => {
    const releaseKey = callReleaseKey(callSid, scope);
    if (lockSetRef.value.has(releaseKey)) return null;

    lockSetRef.value.add(releaseKey);
    try {
      return await callback();
    } finally {
      lockSetRef.value.delete(releaseKey);
    }
  };

  const waitForOperatorReleaseHeadStart = releasePromise => {
    return Promise.race([
      releasePromise,
      new Promise(resolve => {
        setTimeout(resolve, 300);
      }),
    ]);
  };

  const browserSipCallWithEventScope = (call, detail = {}) => ({
    ...call,
    provider: call?.provider || detail.provider,
    inboxId:
      call?.inboxId || call?.inbox_id || detail.inboxId || detail.inbox_id,
    sipProfileId:
      sipProfileIdForCall(call) || detail.sipProfileId || detail.sip_profile_id,
    janusSessionKey:
      call?.janusSessionKey ||
      call?.janus_session_key ||
      call?.sessionKey ||
      detail.sessionKey ||
      detail.session_key,
  });

  const findDisconnectedBrowserSipCall = event => {
    const detail = event?.detail || {};
    const callRef = detail.callRef || detail.callSid;
    const provider = detail.provider;
    const eventSessionKey = detail.sessionKey || detail.session_key;
    const eventSipProfileId = detail.sipProfileId || detail.sip_profile_id;
    const eventInboxId = detail.inboxId || detail.inbox_id;
    const scopeValueCompatible = (actual, expected) =>
      expected === undefined ||
      expected === null ||
      expected === '' ||
      actual === undefined ||
      actual === null ||
      actual === '' ||
      String(actual) === String(expected);
    const scopeValueMatchesExactly = (actual, expected) =>
      expected === undefined ||
      expected === null ||
      expected === '' ||
      (actual !== undefined &&
        actual !== null &&
        actual !== '' &&
        String(actual) === String(expected));
    const eventScopeCompatible = call =>
      call?.provider === provider &&
      scopeValueCompatible(
        call?.janusSessionKey || call?.janus_session_key || call?.sessionKey,
        eventSessionKey
      ) &&
      scopeValueCompatible(sipProfileIdForCall(call), eventSipProfileId) &&
      scopeValueCompatible(call?.inboxId || call?.inbox_id, eventInboxId);
    const eventScopeMatchesExactly = call =>
      call?.provider === provider &&
      scopeValueMatchesExactly(
        call?.janusSessionKey || call?.janus_session_key || call?.sessionKey,
        eventSessionKey
      ) &&
      scopeValueMatchesExactly(sipProfileIdForCall(call), eventSipProfileId) &&
      scopeValueMatchesExactly(call?.inboxId || call?.inbox_id, eventInboxId);

    if (callRef) {
      const referenceCandidates = callsStore.calls.filter(item => {
        if (item?.provider !== provider) return false;
        const canonicalRefMatches =
          item.callSid !== undefined &&
          item.callSid !== null &&
          String(item.callSid) === String(callRef);
        const janusRefMatches = [item.janusCallRef, item.janus_call_ref].some(
          candidate =>
            candidate !== undefined &&
            candidate !== null &&
            String(candidate) === String(callRef)
        );
        return (
          canonicalRefMatches || (Boolean(eventSessionKey) && janusRefMatches)
        );
      });
      const candidates = referenceCandidates.filter(eventScopeCompatible);
      if (candidates.length !== 1) return null;
      if (
        referenceCandidates.length > 1 &&
        !eventScopeMatchesExactly(candidates[0])
      ) {
        return null;
      }
      return candidates[0];
    }

    const currentActiveCall = callsStore.activeCall;
    if (!eventSessionKey || !eventScopeMatchesExactly(currentActiveCall)) {
      return null;
    }
    return currentActiveCall;
  };

  const handleClientConnected = event => {
    const detail = event?.detail || {};
    if (detail.aiBridge || detail.callMode === 'ai') return;
    if (!NATIVE_BROWSER_SIP_PROVIDERS.has(detail.provider)) return;

    const trackedCall = findDisconnectedBrowserSipCall(event);
    if (!trackedCall?.callSid) return;

    const call = browserSipCallWithEventScope(trackedCall, detail);
    callsStore.addCall(call);
    callsStore.setCallActive(call.callSid, call.provider, call);
  };

  const handleClientStage = event => {
    const detail = event?.detail || {};
    if (detail.aiBridge || detail.callMode === 'ai') return;

    const trackedCall = findDisconnectedBrowserSipCall(event);
    if (!trackedCall?.callSid) return;

    const call = browserSipCallWithEventScope(trackedCall, detail);
    const stage = detail.stage;
    if (!isOutboundCallDirection(call.callDirection)) {
      if (stage !== 'accepted') return;

      const answeredAt =
        call.answeredAt || call.answered_at || new Date().toISOString();
      callsStore.addCall({
        callSid: call.callSid,
        provider: call.provider,
        inboxId: call.inboxId || call.inbox_id,
        sipProfileId: sipProfileIdForCall(call),
        janusSessionKey:
          call.janusSessionKey || call.janus_session_key || call.sessionKey,
        status: 'in_progress',
        callEvent: 'operator_answered',
        callLeg: 'operator',
        rawStatus: 'answered',
        browserStartState: 'connected',
        answeredAt,
      });
      VoiceAPI.reportBrowserSipAnswered(call.callSid, {
        answered_at: answeredAt,
      }).catch(() => null);
      callsStore.setCallActive(call.callSid, call.provider, call);
      return;
    }

    const updates = {
      callSid: call.callSid,
      provider: call.provider,
      inboxId: call.inboxId || call.inbox_id,
      sipProfileId: sipProfileIdForCall(call),
      janusSessionKey:
        call.janusSessionKey || call.janus_session_key || call.sessionKey,
      browserStartState: stage,
    };
    if (['call_sent', 'calling'].includes(stage)) {
      Object.assign(updates, { callEvent: 'operator_answered' });
    } else if (stage === 'progress') {
      Object.assign(updates, {
        callEvent: 'callee_ringing',
        callLeg: 'callee',
        rawStatus: 'ringing',
        browserStartState: 'ringing',
      });
    } else if (stage === 'accepted') {
      const answeredAt =
        call.answeredAt || call.answered_at || new Date().toISOString();
      Object.assign(updates, {
        status: 'in_progress',
        callEvent: 'callee_answered',
        callLeg: 'callee',
        rawStatus: 'answered',
        browserStartState: 'connected',
        answeredAt,
      });
      VoiceAPI.reportBrowserSipAnswered(call.callSid, {
        answered_at: answeredAt,
      }).catch(() => null);
    }
    callsStore.addCall(updates);
    if (stage === 'accepted') {
      callsStore.setCallActive(call.callSid, call.provider, call);
    }
  };

  const browserSipDisconnectRelease = (call, detail = {}) => {
    if (call?.isActive || detail.callMediaAccepted) {
      return {
        status: 'completed',
        reason: detail.reason || 'remote_hangup',
      };
    }

    if (isOutboundCallDirection(call?.callDirection)) {
      return {
        status: 'failed',
        reason: detail.reason || 'sip_outbound_disconnected',
      };
    }

    return {
      status: 'no_answer',
      reason: detail.reason || 'remote_hangup',
    };
  };

  const handleBrowserSipClientDisconnect = async (call, detail = {}) => {
    if (!call?.callSid) {
      await callsStore.clearActiveCall();
      return;
    }

    const release = browserSipDisconnectRelease(call, detail);
    const endedAt =
      detail.endedAt || detail.ended_at || new Date().toISOString();
    // Janus BYE is authoritative for this browser leg. Remember it locally so
    // a delayed incoming ActionCable event cannot resurrect the modal while
    // the terminal backend request is still in flight.
    callsStore.rememberTerminalCall({ ...call, status: release.status });

    const releasePromise = runOnceForCall(
      endingCallSids,
      call.callSid,
      async () => {
        const answeredAt =
          call.answeredAt ||
          call.answered_at ||
          detail.answeredAt ||
          detail.answered_at ||
          (detail.callMediaAccepted ? new Date().toISOString() : null);
        const answerReport = answeredAt
          ? VoiceAPI.reportBrowserSipAnswered(call.callSid, {
              answered_at: answeredAt,
            }).catch(() => null)
          : null;
        await Promise.all([
          answerReport,
          releaseBrowserSipCall(call.callSid, {
            status: release.status,
            reason: release.reason,
            endedAt,
          }),
        ]);
      },
      call
    );

    // Persist the terminal state immediately. Browser media cleanup can wait
    // for a recording upload and must not keep the operator busy meanwhile.
    const cleanupPromise = call.isActive
      ? callsStore.clearActiveCall(call)
      : Promise.resolve(
          callsStore.dismissCall(call.callSid, call.provider, call)
        );

    await Promise.all([releasePromise, cleanupPromise]);
  };

  const handleClientDisconnect = async event => {
    if (event?.detail?.aiBridge || event?.detail?.callMode === 'ai') return;

    const detail = event?.detail || {};
    const detailProvider = detail.provider;
    const nativeProvider = NATIVE_BROWSER_SIP_PROVIDERS.has(detailProvider);
    let trackedCall;
    if (nativeProvider) {
      trackedCall = findDisconnectedBrowserSipCall(event);
    } else {
      const callRef = detail.callRef || detail.callSid;
      if (detailProvider && !callRef) return;
      if (callRef) {
        const candidates = callsStore.calls.filter(call => {
          if (detailProvider && call?.provider !== detailProvider) return false;
          return [call?.callSid, call?.callRef, call?.call_ref].some(
            candidate =>
              candidate !== undefined &&
              candidate !== null &&
              String(candidate) === String(callRef)
          );
        });
        if (candidates.length !== 1) return;
        [trackedCall] = candidates;
      } else {
        trackedCall = callsStore.activeCall;
      }
    }

    if (nativeProvider && !trackedCall) return;

    const call = browserSipCallWithEventScope(trackedCall, detail);
    if (NATIVE_BROWSER_SIP_PROVIDERS.has(resolveCallProvider(call))) {
      await handleBrowserSipClientDisconnect(call, detail);
      // eslint-disable-next-line no-use-before-define
      await flushPendingWebphoneConfigRefresh();
      return;
    }

    if (!call?.callSid) return;
    await callsStore.clearActiveCall(call);
    // eslint-disable-next-line no-use-before-define
    await flushPendingWebphoneConfigRefresh();
  };

  const browserSipAiStreamUrl = call => {
    const aiVoice = call.ai_voice || call.aiVoice || {};
    const runtimeResponse =
      aiVoice.runtime_response || aiVoice.runtimeResponse || {};
    const bridge =
      runtimeResponse.browser_bridge ||
      runtimeResponse.browserBridge ||
      aiVoice.browser_bridge ||
      aiVoice.browserBridge ||
      {};
    return bridge.stream_url || bridge.streamUrl;
  };

  const answerBrowserSipAiCall = async (call, detail = {}) => {
    const streamUrl = browserSipAiStreamUrl(call);
    if (!streamUrl) {
      // eslint-disable-next-line no-console
      console.warn('AI voice browser bridge stream URL is missing');
      return;
    }

    try {
      await WebphoneClient.answerAiIncomingCall({
        provider: call.provider || detail.provider,
        inboxId: call.inboxId || call.inbox_id || detail.inboxId,
        sessionKey:
          call.janusSessionKey ||
          call.janus_session_key ||
          detail.sessionKey ||
          detail.session_key,
        sipProfileId:
          call.sipProfileId || call.sip_profile_id || detail.sipProfileId,
        callRef: call.callSid || call.call_sid || call.call_ref,
        janusCallRef:
          call.janusCallRef ||
          call.janus_call_ref ||
          detail.janusCallRef ||
          detail.janus_call_ref ||
          detail.callRef ||
          detail.callSid,
        streamUrl,
      });
    } catch (error) {
      // eslint-disable-next-line no-console
      console.warn('Failed to answer browser SIP call with AI bridge:', error);
    }
  };

  const handleClientIncoming = async event => {
    const detail = event?.detail || {};
    const provider = detail.provider;
    if (!BROWSER_SIP_INCOMING_REPORT_PROVIDERS.has(provider)) return;
    if (!detail.callRef && !detail.callSid) return;

    try {
      const call = await VoiceAPI.reportBrowserSipIncoming({
        provider,
        inbox_id: detail.inboxId || detail.inbox_id,
        call_ref: detail.callRef || detail.callSid,
        from: detail.from || detail.fromNumber || detail.from_number,
        session_key: detail.sessionKey || detail.session_key,
        sip_profile_id: detail.sipProfileId || detail.sip_profile_id,
        registration_instance_id:
          detail.registrationInstanceId || detail.registration_instance_id,
        registration_config_version:
          detail.registrationConfigVersion ||
          detail.registration_config_version,
        janus_session_id: detail.janusSessionId || detail.janus_session_id,
        janus_handle_id: detail.janusHandleId || detail.janus_handle_id,
        janus_unique_id: detail.janusUniqueId || detail.janus_unique_id,
        janus_master_id: detail.janusMasterId || detail.janus_master_id,
        internal_extension:
          detail.internalExtension || detail.internal_extension,
        sip_username: detail.sipUsername || detail.sip_username,
        sip_host: detail.sipHost || detail.sip_host,
        agent_aor: detail.agentAor || detail.agent_aor,
      });
      if ((call.route_action || call.routeAction) === 'ai') {
        await answerBrowserSipAiCall(call, detail);
        return;
      }

      callsStore.addCall({
        callSid: call.callSid || call.call_sid || call.call_ref,
        status: call.status || 'ringing',
        conversationId: call.conversation_id,
        conversationDbId: call.conversation_db_id,
        conversationDisplayId: call.conversation_display_id,
        communicationThreadId:
          call.communication_thread_id || call.communicationThreadId,
        inboxId: call.inboxId || call.inbox_id || detail.inboxId,
        provider: call.provider || provider,
        callDirection: call.call_direction || call.direction || 'inbound',
        contactId: call.contact_id,
        senderId: call.sender_id,
        fromNumber: call.from_number || call.fromNumber || detail.from,
        toNumber: call.to_number || call.toNumber,
        caller: call.caller,
        operatorCandidates: call.operator_candidates || call.operatorCandidates,
        operatorInternalExtension:
          call.operator_internal_extension ||
          call.operatorInternalExtension ||
          detail.internalExtension ||
          detail.internal_extension,
        sipProfileId:
          call.sipProfileId || call.sip_profile_id || detail.sipProfileId,
        janusCallRef:
          call.janusCallRef ||
          call.janus_call_ref ||
          detail.janusCallRef ||
          detail.janus_call_ref ||
          detail.callRef ||
          detail.callSid,
        janusSessionKey:
          call.janusSessionKey ||
          call.janus_session_key ||
          detail.sessionKey ||
          detail.session_key,
        sipuniNativeWebphoneCorrelation:
          call.sipuniNativeWebphoneCorrelation ??
          call.sipuni_native_webphone_correlation,
        browserJoinSupported:
          call.browserJoinSupported ?? call.browser_join_supported ?? true,
      });
    } catch (error) {
      if (STALE_BROWSER_SIP_INCOMING_STATUSES.has(error?.response?.status)) {
        await WebphoneClient.destroyDevice({
          provider,
          inboxId: detail.inboxId || detail.inbox_id,
          sessionKey: detail.sessionKey || detail.session_key,
          sipProfileId: detail.sipProfileId || detail.sip_profile_id,
        });
      }
      // eslint-disable-next-line no-console
      console.warn('Failed to report browser SIP incoming call:', error);
    }
  };

  const normalizeWebphoneConfigRefresh = (data = {}) => ({
    provider: data?.provider || data?.provider_kind || data?.providerKind,
    inboxId: data?.inbox_id || data?.inboxId || null,
    sipProfileId: data?.sip_profile_id || data?.sipProfileId,
    sessionKey: data?.session_key || data?.sessionKey,
    configVersion:
      data?.webphone_config_version ||
      data?.webphoneConfigVersion ||
      data?.registration_config_version ||
      data?.registrationConfigVersion ||
      null,
  });

  const mergeWebphoneConfigRefresh = (current = null, next = {}) => ({
    provider: next.provider || current?.provider || null,
    inboxId: next.inboxId || current?.inboxId || null,
    sipProfileId: next.sipProfileId || current?.sipProfileId || null,
    sessionKey: next.sessionKey || current?.sessionKey || null,
    configVersion: next.configVersion || current?.configVersion || null,
  });

  const sameWebphoneConfigRefresh = (left, right) => {
    if (!left && !right) return true;
    if (!left || !right) return false;

    return (
      left.provider === right.provider &&
      left.inboxId === right.inboxId &&
      left.sipProfileId === right.sipProfileId &&
      left.sessionKey === right.sessionKey &&
      left.configVersion === right.configVersion
    );
  };

  const hasPendingOutboundBrowserSipCall = () =>
    callsStore.calls.some(call => {
      if (!isOutboundCallDirection(call?.callDirection)) return false;
      if (!NATIVE_BROWSER_SIP_PROVIDERS.has(resolveCallProvider(call))) {
        return false;
      }

      const stage = call.browserStartState || call.browser_start_state;
      return (
        call.browserJoined === true ||
        call.browser_joined === true ||
        ['preparing', 'call_sent', 'calling', 'ringing', 'progress'].includes(
          stage
        )
      );
    });

  const hasBusyWebphoneState = payload => {
    if (isJoining.value) return true;
    if (hasActiveCall.value) return true;
    if (incomingCalls.value.length > 0) return true;
    if (hasPendingOutboundBrowserSipCall()) return true;

    return WebphoneClient.hasPendingIncomingCall(payload);
  };

  const refreshWebphoneConfig = async payload => {
    await WebphoneClient.destroyDevice(payload);
    // eslint-disable-next-line no-use-before-define
    await bootstrapIncomingSupport(payload.inboxId);
  };

  const runWebphoneConfigRefresh = async (payload, refreshVersion) => {
    if (isRefreshingWebphoneConfig.value) return;

    isRefreshingWebphoneConfig.value = true;
    let succeeded = false;
    try {
      await refreshWebphoneConfig(payload);
      succeeded = true;
      if (
        pendingWebphoneConfigRefresh.value === payload &&
        webphoneConfigRefreshVersion === refreshVersion
      ) {
        pendingWebphoneConfigRefresh.value = null;
      }
    } finally {
      isRefreshingWebphoneConfig.value = false;
      if (
        succeeded &&
        pendingWebphoneConfigRefresh.value &&
        !hasBusyWebphoneState(pendingWebphoneConfigRefresh.value)
      ) {
        // eslint-disable-next-line no-use-before-define
        flushPendingWebphoneConfigRefresh();
      }
    }
  };

  async function flushPendingWebphoneConfigRefresh() {
    const payload = pendingWebphoneConfigRefresh.value;
    if (!payload) return;
    if (hasBusyWebphoneState(payload)) return;

    try {
      await runWebphoneConfigRefresh(payload, webphoneConfigRefreshVersion);
    } catch (error) {
      // eslint-disable-next-line no-console
      console.warn('Failed to refresh browser SIP config:', error);
    }
  }

  async function requestWebphoneConfigRefresh(data) {
    const current = pendingWebphoneConfigRefresh.value;
    const next = normalizeWebphoneConfigRefresh(data);
    const hasRefreshContext = Boolean(
      next.provider || next.inboxId || next.sipProfileId || next.sessionKey
    );
    const payload = hasRefreshContext
      ? mergeWebphoneConfigRefresh(current, next)
      : current || mergeWebphoneConfigRefresh(null, next);
    if (
      isRefreshingWebphoneConfig.value &&
      current &&
      sameWebphoneConfigRefresh(current, payload)
    ) {
      return;
    }

    webphoneConfigRefreshVersion += 1;
    pendingWebphoneConfigRefresh.value = payload;
    const refreshPayload = pendingWebphoneConfigRefresh.value;

    if (hasBusyWebphoneState(refreshPayload)) return;

    try {
      await runWebphoneConfigRefresh(
        refreshPayload,
        webphoneConfigRefreshVersion
      );
    } catch (error) {
      // eslint-disable-next-line no-console
      console.warn('Failed to refresh browser SIP config:', error);
    }
  }

  const handleWebphoneConfigChanged = data => {
    requestWebphoneConfigRefresh(data);
  };

  function clearBootstrapRetry() {
    if (!bootstrapRetryTimer) return;

    window.clearTimeout(bootstrapRetryTimer);
    bootstrapRetryTimer = null;
  }

  function clearBootstrapRefresh() {
    if (!bootstrapRefreshTimer) return;

    window.clearInterval(bootstrapRefreshTimer);
    bootstrapRefreshTimer = null;
  }

  function startBootstrapRefresh() {
    clearBootstrapRefresh();
    bootstrapRefreshTimer = window.setInterval(() => {
      requestWebphoneConfigRefresh();
    }, INCOMING_BOOTSTRAP_REFRESH_MS);
  }

  async function performBootstrapIncomingSupport(inboxId) {
    const refreshContext = {
      provider:
        incomingCallProviderForInboxId(inboxId) ||
        browserSipProviderForInboxId(inboxId),
      inboxId,
    };
    // Never touch the Janus registration that currently owns an INVITE. A
    // route/store update for that same incoming call must not replace the SIP
    // handle before the operator can answer it.
    if (WebphoneClient.hasPendingIncomingCall(refreshContext)) return null;

    if (
      isJoining.value ||
      hasActiveCall.value ||
      hasPendingOutboundBrowserSipCall()
    ) {
      deferredBootstrapInboxId = positiveNumber(inboxId) || null;
      return null;
    }

    try {
      if (inboxId) {
        await initializeWebphoneDevice(inboxId, {
          provider: incomingCallProviderForInboxId(inboxId),
        });
      } else if (routeInboxId.value) {
        await WebphoneClient.initializeDevice(routeInboxId.value, {
          native: true,
        });
      } else {
        await WebphoneClient.bootstrapIncomingSupport();
      }
      clearBootstrapRetry();
    } catch (error) {
      // eslint-disable-next-line no-console
      console.error('Failed to bootstrap browser calling:', error);
      clearBootstrapRetry();
      bootstrapRetryTimer = window.setTimeout(
        // eslint-disable-next-line no-use-before-define
        bootstrapIncomingSupport,
        INCOMING_BOOTSTRAP_RETRY_MS
      );
    }

    return null;
  }

  function bootstrapIncomingSupport(
    inboxId = routeVoiceInboxId.value ||
      routeCommunicationThreadVoiceInboxId.value ||
      incomingVoiceInboxId.value
  ) {
    const normalizedInboxId = positiveNumber(inboxId) || null;
    if (bootstrapIncomingPromise) {
      if (normalizedInboxId !== activeBootstrapInboxId) {
        pendingBootstrapInboxId = normalizedInboxId;
      }
      return bootstrapIncomingPromise;
    }

    activeBootstrapInboxId = normalizedInboxId;
    bootstrapIncomingPromise = performBootstrapIncomingSupport(
      normalizedInboxId
    ).finally(() => {
      bootstrapIncomingPromise = null;
      activeBootstrapInboxId = undefined;

      if (pendingBootstrapInboxId === undefined) return null;

      const nextInboxId = pendingBootstrapInboxId;
      pendingBootstrapInboxId = undefined;
      // eslint-disable-next-line no-use-before-define
      return bootstrapIncomingSupport(nextInboxId);
    });

    return bootstrapIncomingPromise;
  }

  watch(routeVoiceInboxId, (inboxId, previousInboxId) => {
    if (!inboxId || String(inboxId) === String(previousInboxId)) return;

    bootstrapIncomingSupport(inboxId);
  });

  watch(routeInboxId, (inboxId, previousInboxId) => {
    if (!inboxId || String(inboxId) === String(previousInboxId)) return;
    if (routeVoiceInboxId.value) return;

    bootstrapIncomingSupport();
  });

  watch(routeCommunicationThreadVoiceInboxId, (inboxId, previousInboxId) => {
    if (!inboxId || String(inboxId) === String(previousInboxId)) return;

    bootstrapIncomingSupport(inboxId);
  });

  watch(
    incomingVoiceInboxId,
    (inboxId, previousInboxId) => {
      if (!inboxId || String(inboxId) === String(previousInboxId)) return;

      bootstrapIncomingSupport(inboxId);
    },
    { immediate: true }
  );

  watch(
    () => [hasActiveCall.value, incomingCalls.value.length, isJoining.value],
    ([active, incomingCount, joining]) => {
      if (active || incomingCount > 0 || joining) return;

      flushPendingWebphoneConfigRefresh();
      if (deferredBootstrapInboxId === undefined) return;

      const inboxId = deferredBootstrapInboxId;
      deferredBootstrapInboxId = undefined;
      bootstrapIncomingSupport(inboxId);
    },
    { immediate: true }
  );

  onMounted(() => {
    WebphoneClient.addEventListener('call:connected', handleClientConnected);
    WebphoneClient.addEventListener(
      'call:disconnected',
      handleClientDisconnect
    );
    WebphoneClient.addEventListener('call:incoming', handleClientIncoming);
    WebphoneClient.addEventListener('call:stage', handleClientStage);
    emitter.on(
      BUS_EVENTS.TELEPHONY_WEBPHONE_CONFIG_CHANGED,
      handleWebphoneConfigChanged
    );

    bootstrapIncomingSupport();
    startBootstrapRefresh();
  });

  onUnmounted(() => {
    durationTimer.stop();
    clearBootstrapRetry();
    clearBootstrapRefresh();
    pendingBootstrapInboxId = undefined;
    deferredBootstrapInboxId = undefined;
    pendingWebphoneConfigRefresh.value = null;
    emitter.off(
      BUS_EVENTS.TELEPHONY_WEBPHONE_CONFIG_CHANGED,
      handleWebphoneConfigChanged
    );
    WebphoneClient.removeEventListener(
      'call:disconnected',
      handleClientDisconnect
    );
    WebphoneClient.removeEventListener('call:connected', handleClientConnected);
    WebphoneClient.removeEventListener('call:incoming', handleClientIncoming);
    WebphoneClient.removeEventListener('call:stage', handleClientStage);
  });

  const endCall = async call => {
    const { conversationId, inboxId, provider, callSid } = call;
    if (NATIVE_BROWSER_SIP_PROVIDERS.has(provider)) {
      return runOnceForCall(
        endingCallSids,
        callSid,
        async () => {
          const trackedCall = trackedCallForSid(callSid, call);
          const localCallScope = janusWebphoneCallScope({
            ...(trackedCall || {}),
            ...call,
          });
          const releaseResult = releaseBrowserSipCall(callSid, {
            status: 'completed',
            reason: 'operator_hangup',
            endedAt: new Date().toISOString(),
          });

          await waitForOperatorReleaseHeadStart(releaseResult);
          try {
            await WebphoneClient.endClientCall(localCallScope);
          } catch (error) {
            // eslint-disable-next-line no-console
            console.warn('Failed to end browser SIP call:', error);
          }

          durationTimer.stop();
          callDuration.value = 0;
          callsStore.dismissCall(callSid, provider, call);
          flushPendingWebphoneConfigRefresh();
          return releaseResult;
        },
        call
      );
    }

    await VoiceAPI.leaveConference(inboxId, conversationId);
    await WebphoneClient.endClientCall(call);
    const clearedActiveCall = await callsStore.clearActiveCall(call);
    if (clearedActiveCall) {
      durationTimer.stop();
    } else {
      callsStore.dismissCall(call.callSid, provider, call);
    }
    flushPendingWebphoneConfigRefresh();
    return null;
  };

  const cancelNativeOutboundCall = async call => {
    const callSid = call?.callSid;
    if (!callSid) return null;

    return runOnceForCall(
      releasingCallSids,
      callSid,
      async () => {
        const releaseResult = releaseBrowserSipCall(callSid, {
          status: 'cancelled',
          reason: 'operator_cancelled',
        });

        await waitForOperatorReleaseHeadStart(releaseResult);
        try {
          await WebphoneClient.endClientCall(janusWebphoneCallScope(call));
        } catch (error) {
          // eslint-disable-next-line no-console
          console.warn('Failed to cancel browser SIP call:', error);
        }

        durationTimer.stop();
        callDuration.value = 0;
        callsStore.dismissCall(callSid, call?.provider, call);
        flushPendingWebphoneConfigRefresh();
        return releaseResult;
      },
      call
    );
  };

  const joinCall = async ({
    conversationId,
    inboxId,
    callSid,
    provider,
    callDirection,
    toNumber,
    sipProfileId,
    janusCallRef,
    janus_call_ref,
    janusSessionKey,
    janus_session_key,
  }) => {
    if (isJoining.value) return null;

    isJoining.value = true;
    try {
      const incomingNativeScope = {
        provider,
        inboxId,
        sipProfileId,
        sessionKey: janusSessionKey || janus_session_key,
        callRef: callSid,
        janusCallRef: janusCallRef || janus_call_ref,
      };
      const isInboundNativeCall =
        !isOutboundCallDirection(callDirection) &&
        NATIVE_BROWSER_SIP_PROVIDERS.has(provider);
      const trackedIncomingCall =
        trackedCallForSid(callSid, incomingNativeScope) || {};
      const authoritativeJanusCallRef =
        janusCallRef ||
        janus_call_ref ||
        janusCallRefForCall(trackedIncomingCall);
      const incomingSessionCandidate = isInboundNativeCall
        ? WebphoneClient.getSession(provider, incomingNativeScope)
        : null;
      const sameScopeValue = (actual, expected) =>
        expected === undefined ||
        expected === null ||
        expected === '' ||
        String(actual) === String(expected);
      const candidateMatchesScope = Boolean(
        incomingSessionCandidate &&
          incomingSessionCandidate.provider === provider &&
          sameScopeValue(incomingSessionCandidate.inboxId, inboxId) &&
          sameScopeValue(incomingSessionCandidate.sipProfileId, sipProfileId) &&
          sameScopeValue(
            incomingSessionCandidate.sessionKey,
            incomingNativeScope.sessionKey
          )
      );
      const readyIncomingSession =
        candidateMatchesScope &&
        Boolean(authoritativeJanusCallRef) &&
        WebphoneClient.hasPendingIncomingCall({
          ...incomingNativeScope,
          sessionKey: incomingSessionCandidate.sessionKey,
        })
          ? incomingSessionCandidate
          : null;
      const webphoneSession =
        readyIncomingSession?.callingSupported !== false &&
        readyIncomingSession?.registered === true
          ? readyIncomingSession
          : await initializeWebphoneDevice(inboxId, {
              provider,
              sipProfileId,
              sessionKey: incomingNativeScope.sessionKey,
            });
      if (!webphoneSession) return null;

      if (!webphoneSession.callingSupported) {
        callsStore.markBrowserJoinUnsupported(
          callSid,
          webphoneSession.provider,
          {},
          {
            inboxId,
            sipProfileId,
            janusSessionKey:
              webphoneSession.sessionKey || webphoneSession.session_key,
          }
        );
        return {
          provider: webphoneSession.provider,
          joinSupported: false,
        };
      }

      const resolvedProvider = webphoneSession.provider || provider;

      if (NATIVE_BROWSER_SIP_PROVIDERS.has(resolvedProvider)) {
        const isOutbound = isOutboundCallDirection(callDirection);
        const trackedCall = trackedIncomingCall;
        const joinCallData = {
          ...trackedCall,
          callSid,
          provider: resolvedProvider,
          inboxId: inboxId || trackedCall.inboxId || trackedCall.inbox_id,
          callDirection: callDirection || trackedCall.callDirection,
          sipProfileId: sipProfileId || trackedCall.sipProfileId,
          sip_profile_id: sipProfileId || trackedCall.sip_profile_id,
          janusCallRef:
            janusCallRef || janus_call_ref || trackedCall.janusCallRef,
          janus_call_ref:
            janusCallRef || janus_call_ref || trackedCall.janus_call_ref,
          janusSessionKey:
            webphoneSession.sessionKey ||
            webphoneSession.session_key ||
            janusSessionKey ||
            janus_session_key ||
            (candidateMatchesScope
              ? incomingSessionCandidate?.sessionKey
              : null) ||
            trackedCall.janusSessionKey ||
            trackedCall.janus_session_key,
          janus_session_key:
            webphoneSession.sessionKey ||
            webphoneSession.session_key ||
            janusSessionKey ||
            janus_session_key ||
            (candidateMatchesScope
              ? incomingSessionCandidate?.sessionKey
              : null) ||
            trackedCall.janus_session_key ||
            trackedCall.janusSessionKey,
        };
        let communicationThreadId = null;
        let operatorSipProfileId =
          webphoneSession.sipProfileId ||
          webphoneSession.sip_profile_id ||
          sipProfileIdForCall(joinCallData);
        const scopedJoinCall = () => ({
          ...joinCallData,
          sipProfileId:
            operatorSipProfileId || sipProfileIdForCall(joinCallData),
        });

        if (!isOutbound) {
          if (
            JANUS_NATIVE_BROWSER_SIP_PROVIDERS.has(resolvedProvider) &&
            authoritativeJanusCallRef
          ) {
            const pendingIncomingCall =
              await WebphoneClient.waitForPendingIncomingCall(
                {
                  ...janusWebphoneCallScope({
                    ...joinCallData,
                    sipProfileId: operatorSipProfileId,
                  }),
                },
                { timeoutMs: 2500 }
              );
            if (!pendingIncomingCall) {
              return failNativeBrowserSipCallWithoutInvite(callSid, {
                provider: resolvedProvider,
                communicationThreadId:
                  trackedCall.communicationThreadId ||
                  trackedCall.communication_thread_id,
                scope: scopedJoinCall(),
              });
            }
          }

          const claimResult = await claimBrowserSipIncomingCall(callSid);
          operatorSipProfileId =
            operatorSipProfileId ||
            sipProfileIdForCall({
              operatorClaim: operatorClaimFromDetails(claimResult.details),
              operatorCandidates:
                claimResult?.operator_candidates ||
                claimResult?.operatorCandidates,
            });
          if (!claimResult.claimed) {
            const reason = claimResult.reason || claimResult.code;
            if (shouldRetryClaimFailure(claimResult)) {
              return {
                provider: resolvedProvider,
                joinSupported: false,
                retryable: true,
                reason,
              };
            }
            callsStore.markBrowserJoinUnsupported(
              callSid,
              resolvedProvider,
              {
                reason,
                operatorClaim: operatorClaimFromDetails(claimResult.details),
              },
              scopedJoinCall()
            );
            if (shouldDismissClaimFailure(claimResult)) {
              callsStore.dismissCall(
                callSid,
                resolvedProvider,
                scopedJoinCall()
              );
            }
            return {
              provider: resolvedProvider,
              joinSupported: false,
              reason,
              ...(communicationThreadId ? { communicationThreadId } : {}),
            };
          }
          communicationThreadId = claimResult.communicationThreadId;
          if (communicationThreadId) {
            callsStore.addCall({
              callSid,
              status: JANUS_NATIVE_BROWSER_SIP_PROVIDERS.has(resolvedProvider)
                ? 'connecting'
                : claimResult.status,
              conversationId,
              communicationThreadId,
              inboxId,
              provider: resolvedProvider,
              callDirection: joinCallData.callDirection,
              sipProfileId: operatorSipProfileId,
              janusCallRef: janusCallRefForCall(joinCallData),
              janusSessionKey:
                joinCallData.janusSessionKey || joinCallData.janus_session_key,
            });
          }

          if (
            JANUS_NATIVE_BROWSER_SIP_PROVIDERS.has(resolvedProvider) &&
            !janusCallRefForCall(joinCallData)
          ) {
            return releaseClaimedNativeBrowserSipCallWithoutInvite(callSid, {
              provider: resolvedProvider,
              communicationThreadId,
              scope: scopedJoinCall(),
            });
          }
        }

        let joinResult = null;
        try {
          joinResult = await WebphoneClient.joinClientCall({
            provider: resolvedProvider,
            inboxId,
            sipProfileId: operatorSipProfileId,
            conversationId,
            callRef: callSid,
            callDirection,
            toNumber,
            sessionKey:
              joinCallData.janusSessionKey || joinCallData.janus_session_key,
            janusCallRef: janusCallRefForCall(joinCallData),
          });
        } catch (error) {
          // eslint-disable-next-line no-console
          console.warn('Failed to answer browser SIP call:', error);
          if (isOutbound) {
            if (!hasTrackedCall(callSid, scopedJoinCall())) {
              return {
                provider: resolvedProvider,
                joinSupported: false,
                reason: 'call_closed',
                callSid,
              };
            }

            return failNativeOutboundStart(callSid, {
              provider: resolvedProvider,
              error,
              scope: scopedJoinCall(),
            });
          }

          const releaseResult = await releaseUnsupportedBrowserSipJoin(
            callSid,
            {
              includeReason: true,
              provider: resolvedProvider,
              scope: scopedJoinCall(),
            }
          );
          return {
            ...releaseResult,
            ...(communicationThreadId ? { communicationThreadId } : {}),
          };
        }

        if (!joinResult) {
          if (isOutbound) {
            if (!hasTrackedCall(callSid, scopedJoinCall())) {
              return {
                provider: resolvedProvider,
                joinSupported: false,
                reason: 'call_closed',
                callSid,
              };
            }

            return failNativeOutboundStart(callSid, {
              provider: resolvedProvider,
              scope: scopedJoinCall(),
            });
          }

          return releaseClaimedNativeBrowserSipCallWithoutInvite(callSid, {
            provider: resolvedProvider,
            communicationThreadId,
            scope: scopedJoinCall(),
          });
        }

        if (isOutbound) {
          callsStore.markBrowserJoined(callSid, resolvedProvider, joinCallData);
          return {
            provider: resolvedProvider,
            joinSupported: true,
            waitingForAnswer: true,
          };
        }

        callsStore.setCallActive(callSid, resolvedProvider, joinCallData);

        return {
          provider: resolvedProvider,
          joinSupported: true,
          communicationThreadId,
        };
      }

      const joinResponse = await VoiceAPI.joinConference({
        conversationId,
        inboxId,
        callSid,
      });

      const joinSupported = joinResponse?.join_supported !== false;

      if (!joinSupported) {
        callsStore.markBrowserJoinUnsupported(
          callSid,
          joinResponse?.provider || webphoneSession.provider
        );
        return {
          provider: joinResponse?.provider || webphoneSession.provider,
          joinSupported: false,
        };
      }

      await WebphoneClient.joinClientCall({
        to: joinResponse?.conference_sid || joinResponse?.call_ref,
        conversationId,
        callRef: joinResponse?.call_ref || callSid,
      });

      callsStore.setCallActive(
        callSid,
        joinResponse?.provider || webphoneSession.provider
      );
      durationTimer.start();

      return {
        provider: joinResponse?.provider || webphoneSession.provider,
        conferenceSid: joinResponse?.conference_sid,
        joinSupported: true,
        communicationThreadId:
          joinResponse?.communication_thread_id ||
          joinResponse?.communicationThreadId,
      };
    } catch (error) {
      // eslint-disable-next-line no-console
      console.error('Failed to join call:', error);
      const fallbackProvider =
        provider || trackedCallForSid(callSid, { provider })?.provider;
      if (
        isOutboundCallDirection(callDirection) &&
        NATIVE_BROWSER_SIP_PROVIDERS.has(fallbackProvider)
      ) {
        if (
          !hasTrackedCall(callSid, {
            provider: fallbackProvider,
            inboxId,
            sipProfileId,
            janusSessionKey: janusSessionKey || janus_session_key,
          })
        ) {
          return {
            provider: fallbackProvider,
            joinSupported: false,
            reason: 'call_closed',
            callSid,
          };
        }

        return failNativeOutboundStart(callSid, {
          provider: fallbackProvider,
          error,
          scope: {
            provider: fallbackProvider,
            inboxId,
            sipProfileId,
            janusSessionKey: janusSessionKey || janus_session_key,
          },
        });
      }

      return null;
    } finally {
      isJoining.value = false;
    }
  };

  const rejectIncomingCall = async call => {
    const provider = resolveCallProvider(call);

    if (NATIVE_BROWSER_SIP_PROVIDERS.has(provider)) {
      if (isOutboundCallDirection(call?.callDirection)) {
        return cancelNativeOutboundCall(call);
      }

      if (isAiVoiceCall(call)) {
        callsStore.dismissCall(call?.callSid, provider, call);
        return null;
      }

      const releaseResult = await runOnceForCall(
        releasingCallSids,
        call?.callSid,
        async () => {
          try {
            const rejectScope = janusWebphoneCallScope(call);
            await WebphoneClient.rejectIncomingCall({
              ...rejectScope,
              callRef: rejectScope.janusCallRef ? null : rejectScope.callRef,
            });
          } catch (error) {
            // eslint-disable-next-line no-console
            console.warn('Failed to decline browser SIP call:', error);
          }

          return releaseBrowserSipCall(call?.callSid, {
            status: 'rejected',
            reason: 'operator_declined',
          });
        },
        call
      );
      if (!releaseResult) return null;
    } else {
      await WebphoneClient.endClientCall(provider);
    }

    callsStore.dismissCall(call?.callSid, provider, call);
    return null;
  };

  const dismissCall = (callSid, provider = null) => {
    callsStore.dismissCall(callSid, provider);
  };

  const formattedCallDuration = computed(() => {
    const minutes = Math.floor(callDuration.value / 60);
    const seconds = callDuration.value % 60;
    return `${minutes.toString().padStart(2, '0')}:${seconds.toString().padStart(2, '0')}`;
  });

  const canHandleCallInBrowser = call => {
    const provider = resolveCallProvider(call);
    if (!provider) return false;
    if (call?.browserJoinSupported === false) return false;

    return WebphoneClient.supportsBrowserCalling(provider, {
      callDirection: call?.callDirection,
      inboxId: call?.inboxId || call?.inbox_id,
      sipProfileId: sipProfileIdForCall(call),
    });
  };

  return {
    activeCall,
    incomingCalls,
    hasActiveCall,
    isJoining,
    formattedCallDuration,
    canHandleCallInBrowser,
    joinCall,
    endCall,
    rejectIncomingCall,
    dismissCall,
  };
}
