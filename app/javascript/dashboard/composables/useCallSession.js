import { computed, ref, watch, onUnmounted, onMounted } from 'vue';
import { useRoute } from 'vue-router';
import { useStore } from 'vuex';
import VoiceAPI from 'dashboard/api/channel/voice/voiceAPIClient';
import WebphoneClient from 'dashboard/api/channel/voice/webphoneClient';
import { useCallsStore } from 'dashboard/stores/calls';
import { INBOX_TYPES } from 'dashboard/helper/inbox';
import { isCommunicationThread } from 'dashboard/helper/communicationThreadHelper';
import Timer from 'dashboard/helper/Timer';

const INCOMING_BOOTSTRAP_RETRY_MS = 10_000;
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
  'fonoster',
  'asterisk_analog',
  'sipuni',
  'binotel',
  'twilio',
]);
const NATIVE_BROWSER_SIP_PROVIDERS = new Set([
  'fonoster',
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
  const endingCallSids = ref(new Set());
  const releasingCallSids = ref(new Set());
  let bootstrapRetryTimer = null;
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
    sipProfileId: sipProfileIdForCall(call),
  });
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
  const trackedCallForSid = callSid =>
    callsStore.calls.find(call => String(call.callSid) === String(callSid)) ||
    null;
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
        ['fonoster', 'asterisk_analog', 'sipuni', 'binotel', 'twilio'].includes(
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
  const initializeWebphoneDevice = (inboxId, { provider = null } = {}) => {
    const native = shouldUseNativeWebphoneToken({ inboxId, provider });
    return native
      ? WebphoneClient.initializeDevice(inboxId, { native: true })
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

  const claimFonosterIncomingCall = async callSid => {
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

  const releaseFonosterIncomingCall = async (
    callSid,
    { status = 'rejected', reason = 'operator_declined' } = {}
  ) => {
    if (!callSid) return null;

    try {
      return await VoiceAPI.rejectIncomingCall(callSid, { status, reason });
    } catch (error) {
      // eslint-disable-next-line no-console
      console.warn('Failed to release incoming call:', error);
      return null;
    }
  };

  const releaseUnsupportedFonosterJoin = async (
    callSid,
    { includeReason = false, provider = 'fonoster' } = {}
  ) => {
    await releaseFonosterIncomingCall(callSid, {
      status: 'no_answer',
      reason: 'browser_webphone_not_ready',
    });
    callsStore.markBrowserJoinUnsupported(callSid, provider);
    callsStore.dismissCall(callSid);
    return {
      provider,
      joinSupported: false,
      ...(includeReason ? { reason: 'browser_webphone_not_ready' } : {}),
    };
  };

  const releaseClaimedNativeBrowserSipCallWithoutInvite = async (
    callSid,
    { provider, communicationThreadId = null } = {}
  ) => {
    const releaseResult = await releaseFonosterIncomingCall(callSid, {
      status: 'no_answer',
      reason: 'sip_invite_not_received',
    });
    callsStore.markBrowserJoinUnsupported(callSid, provider, {
      reason: 'sip_invite_not_received',
    });
    if (releaseResult) {
      callsStore.dismissCall(callSid);
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
    { provider, communicationThreadId = null } = {}
  ) => {
    callsStore.markBrowserJoinUnsupported(callSid, provider, {
      reason: 'sip_invite_not_received',
    });

    return {
      provider,
      joinSupported: false,
      reason: 'sip_invite_not_received',
      ...(communicationThreadId ? { communicationThreadId } : {}),
    };
  };

  const failFonosterOutboundWithoutInvite = async callSid => {
    await releaseFonosterIncomingCall(callSid, {
      status: 'failed',
      reason: 'sip_invite_not_received',
    });
    callsStore.dismissCall(callSid);
    return {
      provider: 'fonoster',
      joinSupported: false,
      reason: 'sip_invite_not_received',
      callSid,
    };
  };

  const unknownCallReleaseKey = Symbol('unknown_call');
  const callReleaseKey = callSid => callSid || unknownCallReleaseKey;
  const hasTrackedCall = callSid =>
    callsStore.calls.some(call => String(call.callSid) === String(callSid));

  const runOnceForCall = async (lockSetRef, callSid, callback) => {
    const releaseKey = callReleaseKey(callSid);
    if (lockSetRef.value.has(releaseKey)) return null;

    lockSetRef.value.add(releaseKey);
    try {
      return await callback();
    } finally {
      lockSetRef.value.delete(releaseKey);
    }
  };

  const waitForFonosterOperatorReleaseHeadStart = releasePromise => {
    return Promise.race([
      releasePromise,
      new Promise(resolve => {
        setTimeout(resolve, 300);
      }),
    ]);
  };

  const findDisconnectedBrowserSipCall = event => {
    const detail = event?.detail || {};
    const callRef = detail.callRef || detail.callSid;
    const provider = detail.provider;

    if (callRef) {
      const call = callsStore.calls.find(
        item =>
          item.provider === provider && String(item.callSid) === String(callRef)
      );
      if (call) return call;
    }

    if (resolveCallProvider(callsStore.activeCall) === provider) {
      return callsStore.activeCall;
    }

    return null;
  };

  const handleClientConnected = event => {
    const detail = event?.detail || {};
    if (!NATIVE_BROWSER_SIP_PROVIDERS.has(detail.provider)) return;

    const call = findDisconnectedBrowserSipCall(event);
    if (!call?.callSid) return;

    callsStore.setCallActive(call.callSid);
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

    if (call.isActive) {
      await callsStore.clearActiveCall();
    } else {
      callsStore.dismissCall(call.callSid);
    }

    await runOnceForCall(endingCallSids, call.callSid, async () => {
      const release = browserSipDisconnectRelease(call, detail);
      await releaseFonosterIncomingCall(call.callSid, {
        status: release.status,
        reason: release.reason,
      });
    });
  };

  const handleClientDisconnect = async event => {
    const detailProvider = event?.detail?.provider;
    const call = NATIVE_BROWSER_SIP_PROVIDERS.has(detailProvider)
      ? findDisconnectedBrowserSipCall(event)
      : callsStore.activeCall;

    if (NATIVE_BROWSER_SIP_PROVIDERS.has(detailProvider) && !call) return;

    if (NATIVE_BROWSER_SIP_PROVIDERS.has(resolveCallProvider(call))) {
      await handleBrowserSipClientDisconnect(call, event?.detail || {});
      return;
    }

    await callsStore.clearActiveCall();
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
        internal_extension:
          detail.internalExtension || detail.internal_extension,
      });
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
      // eslint-disable-next-line no-console
      console.warn('Failed to report browser SIP incoming call:', error);
    }
  };

  function clearBootstrapRetry() {
    if (!bootstrapRetryTimer) return;

    window.clearTimeout(bootstrapRetryTimer);
    bootstrapRetryTimer = null;
  }

  const bootstrapIncomingSupport = async (
    inboxId = routeVoiceInboxId.value ||
      routeCommunicationThreadVoiceInboxId.value ||
      incomingVoiceInboxId.value
  ) => {
    try {
      await WebphoneClient.bootstrapIncomingSupport();

      if (inboxId) {
        await initializeWebphoneDevice(inboxId, {
          provider: incomingCallProviderForInboxId(inboxId),
        });
      } else if (routeInboxId.value) {
        await WebphoneClient.initializeDevice(routeInboxId.value, {
          native: true,
        });
      }
      clearBootstrapRetry();
    } catch (error) {
      // eslint-disable-next-line no-console
      console.error('Failed to bootstrap browser calling:', error);
      clearBootstrapRetry();
      bootstrapRetryTimer = window.setTimeout(
        bootstrapIncomingSupport,
        INCOMING_BOOTSTRAP_RETRY_MS
      );
    }
  };

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

  onMounted(() => {
    WebphoneClient.addEventListener('call:connected', handleClientConnected);
    WebphoneClient.addEventListener(
      'call:disconnected',
      handleClientDisconnect
    );
    WebphoneClient.addEventListener('call:incoming', handleClientIncoming);

    bootstrapIncomingSupport();
  });

  onUnmounted(() => {
    durationTimer.stop();
    clearBootstrapRetry();
    WebphoneClient.removeEventListener(
      'call:disconnected',
      handleClientDisconnect
    );
    WebphoneClient.removeEventListener('call:connected', handleClientConnected);
    WebphoneClient.removeEventListener('call:incoming', handleClientIncoming);
  });

  const endCall = async ({ conversationId, inboxId, provider, callSid }) => {
    if (NATIVE_BROWSER_SIP_PROVIDERS.has(provider)) {
      return runOnceForCall(endingCallSids, callSid, async () => {
        const releaseResult = releaseFonosterIncomingCall(callSid, {
          status: 'completed',
          reason: 'operator_hangup',
        });

        await waitForFonosterOperatorReleaseHeadStart(releaseResult);
        try {
          await WebphoneClient.endClientCall({
            provider,
            inboxId,
          });
        } catch (error) {
          // eslint-disable-next-line no-console
          console.warn('Failed to end browser SIP call:', error);
        }

        durationTimer.stop();
        callDuration.value = 0;
        callsStore.dismissCall(callSid);
        return releaseResult;
      });
    }

    await VoiceAPI.leaveConference(inboxId, conversationId);
    await WebphoneClient.endClientCall(provider);
    durationTimer.stop();
    callsStore.clearActiveCall();
    return null;
  };

  const cancelFonosterOutboundCall = async call => {
    const callSid = call?.callSid;
    if (!callSid) return null;

    return runOnceForCall(releasingCallSids, callSid, async () => {
      const releaseResult = releaseFonosterIncomingCall(callSid, {
        status: 'cancelled',
        reason: 'operator_cancelled',
      });

      await waitForFonosterOperatorReleaseHeadStart(releaseResult);
      try {
        await WebphoneClient.endClientCall(webphoneCallScope(call));
      } catch (error) {
        // eslint-disable-next-line no-console
        console.warn('Failed to cancel Fonoster browser call:', error);
      }

      durationTimer.stop();
      callDuration.value = 0;
      callsStore.dismissCall(callSid);
      return releaseResult;
    });
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
  }) => {
    if (isJoining.value) return null;

    isJoining.value = true;
    try {
      const webphoneSession = await initializeWebphoneDevice(inboxId, {
        provider,
      });
      if (!webphoneSession) return null;

      if (!webphoneSession.callingSupported) {
        callsStore.markBrowserJoinUnsupported(
          callSid,
          webphoneSession.provider
        );
        return {
          provider: webphoneSession.provider,
          joinSupported: false,
        };
      }

      const resolvedProvider = webphoneSession.provider || provider;

      if (NATIVE_BROWSER_SIP_PROVIDERS.has(resolvedProvider)) {
        const isOutbound = isOutboundCallDirection(callDirection);
        const trackedCall = trackedCallForSid(callSid) || {};
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
          janusSessionKey: trackedCall.janusSessionKey,
          janus_session_key: trackedCall.janus_session_key,
        };
        let communicationThreadId = null;
        let operatorSipProfileId =
          webphoneSession.sipProfileId ||
          webphoneSession.sip_profile_id ||
          sipProfileIdForCall(joinCallData);

        if (!isOutbound) {
          if (JANUS_NATIVE_BROWSER_SIP_PROVIDERS.has(resolvedProvider)) {
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
              });
            }
          }

          const claimResult = await claimFonosterIncomingCall(callSid);
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
            callsStore.markBrowserJoinUnsupported(callSid, resolvedProvider, {
              reason,
              operatorClaim: operatorClaimFromDetails(claimResult.details),
            });
            if (shouldDismissClaimFailure(claimResult)) {
              callsStore.dismissCall(callSid);
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
            janusCallRef: janusCallRefForCall(joinCallData),
          });
        } catch (error) {
          // eslint-disable-next-line no-console
          console.warn('Failed to answer browser SIP call:', error);
          const releaseResult = await releaseUnsupportedFonosterJoin(callSid, {
            includeReason: true,
            provider: resolvedProvider,
          });
          return {
            ...releaseResult,
            ...(communicationThreadId ? { communicationThreadId } : {}),
          };
        }

        if (!joinResult) {
          if (isOutbound) {
            if (!hasTrackedCall(callSid)) {
              return {
                provider: resolvedProvider,
                joinSupported: false,
                reason: 'call_closed',
                callSid,
              };
            }

            if (resolvedProvider === 'fonoster') {
              return failFonosterOutboundWithoutInvite(callSid);
            }

            return {
              provider: resolvedProvider,
              joinSupported: false,
              reason: 'sip_invite_not_received',
            };
          }

          return releaseClaimedNativeBrowserSipCallWithoutInvite(callSid, {
            provider: resolvedProvider,
            communicationThreadId,
          });
        }

        if (isOutbound) {
          callsStore.markBrowserJoined(callSid, resolvedProvider);
          return {
            provider: resolvedProvider,
            joinSupported: true,
            waitingForAnswer: true,
          };
        }

        callsStore.setCallActive(callSid);

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

      callsStore.setCallActive(callSid);
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
      return null;
    } finally {
      isJoining.value = false;
    }
  };

  const rejectIncomingCall = async call => {
    const provider = resolveCallProvider(call);

    if (NATIVE_BROWSER_SIP_PROVIDERS.has(provider)) {
      if (isOutboundCallDirection(call?.callDirection)) {
        return cancelFonosterOutboundCall(call);
      }

      const releaseResult = await runOnceForCall(
        releasingCallSids,
        call?.callSid,
        async () => {
          try {
            await WebphoneClient.rejectIncomingCall(webphoneCallScope(call));
          } catch (error) {
            // eslint-disable-next-line no-console
            console.warn('Failed to decline browser SIP call:', error);
          }

          return releaseFonosterIncomingCall(call?.callSid, {
            status: 'rejected',
            reason: 'operator_declined',
          });
        }
      );
      if (!releaseResult) return null;
    } else {
      await WebphoneClient.endClientCall(provider);
    }

    callsStore.dismissCall(call?.callSid);
    return null;
  };

  const dismissCall = callSid => {
    callsStore.dismissCall(callSid);
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
