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
const BROWSER_CALLING_PROVIDERS = new Set(['fonoster', 'twilio']);

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
        ['fonoster', 'twilio'].includes(item?.provider) &&
        Number.isFinite(Number(item?.inboxId)) &&
        Number(item.inboxId) > 0
      );
    });

    return call ? Number(call.inboxId) : null;
  });

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

  const claimFonosterIncomingCall = async callSid => {
    try {
      await VoiceAPI.claimIncomingCall(callSid);
      return { claimed: true };
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
    { includeReason = false } = {}
  ) => {
    await releaseFonosterIncomingCall(callSid, {
      status: 'no_answer',
      reason: 'browser_webphone_not_ready',
    });
    callsStore.markBrowserJoinUnsupported(callSid, 'fonoster');
    callsStore.dismissCall(callSid);
    return {
      provider: 'fonoster',
      joinSupported: false,
      ...(includeReason ? { reason: 'browser_webphone_not_ready' } : {}),
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

  const findDisconnectedFonosterCall = event => {
    const detail = event?.detail || {};
    const callRef = detail.callRef || detail.callSid;

    if (callRef) {
      const call = callsStore.calls.find(
        item =>
          item.provider === 'fonoster' &&
          String(item.callSid) === String(callRef)
      );
      if (call) return call;
    }

    if (resolveCallProvider(callsStore.activeCall) === 'fonoster') {
      return callsStore.activeCall;
    }

    return null;
  };

  const handleFonosterClientDisconnect = async call => {
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
      await releaseFonosterIncomingCall(call.callSid, {
        status: 'completed',
        reason: 'remote_hangup',
      });
    });
  };

  const handleClientDisconnect = async event => {
    const detailProvider = event?.detail?.provider;
    const call =
      detailProvider === 'fonoster'
        ? findDisconnectedFonosterCall(event)
        : callsStore.activeCall;

    if (detailProvider === 'fonoster' && !call) return;

    if (resolveCallProvider(call) === 'fonoster') {
      await handleFonosterClientDisconnect(call);
      return;
    }

    await callsStore.clearActiveCall();
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
      if (inboxId) {
        await WebphoneClient.initializeDevice(inboxId);
      } else if (routeInboxId.value || routeCommunicationThreadId.value) {
        return;
      } else {
        await WebphoneClient.bootstrapIncomingSupport();
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
    WebphoneClient.addEventListener(
      'call:disconnected',
      handleClientDisconnect
    );

    bootstrapIncomingSupport();
  });

  onUnmounted(() => {
    durationTimer.stop();
    clearBootstrapRetry();
    WebphoneClient.removeEventListener(
      'call:disconnected',
      handleClientDisconnect
    );
  });

  const endCall = async ({ conversationId, inboxId, provider, callSid }) => {
    if (provider === 'fonoster') {
      return runOnceForCall(endingCallSids, callSid, async () => {
        const releaseResult = releaseFonosterIncomingCall(callSid, {
          status: 'completed',
          reason: 'operator_hangup',
        });

        await waitForFonosterOperatorReleaseHeadStart(releaseResult);
        try {
          await WebphoneClient.endClientCall(provider);
        } catch (error) {
          // eslint-disable-next-line no-console
          console.warn('Failed to end Fonoster browser call:', error);
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
        await WebphoneClient.endClientCall(call?.provider || 'fonoster');
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
  }) => {
    if (isJoining.value) return null;

    isJoining.value = true;
    try {
      const webphoneSession = await WebphoneClient.initializeDevice(inboxId);
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

      if (resolvedProvider === 'fonoster') {
        const isOutbound = isOutboundCallDirection(callDirection);

        if (!isOutbound) {
          const claimResult = await claimFonosterIncomingCall(callSid);
          if (!claimResult.claimed) {
            const reason = claimResult.reason || claimResult.code;
            callsStore.markBrowserJoinUnsupported(callSid, 'fonoster', {
              reason,
              operatorClaim: operatorClaimFromDetails(claimResult.details),
            });
            if (shouldDismissClaimFailure(claimResult)) {
              callsStore.dismissCall(callSid);
            }
            return {
              provider: 'fonoster',
              joinSupported: false,
              reason,
            };
          }
        }

        let joinResult = null;
        try {
          joinResult = await WebphoneClient.joinClientCall({
            provider: 'fonoster',
            conversationId,
            callRef: callSid,
            callDirection,
          });
        } catch (error) {
          // eslint-disable-next-line no-console
          console.warn('Failed to answer Fonoster browser call:', error);
          return releaseUnsupportedFonosterJoin(callSid, {
            includeReason: true,
          });
        }

        if (!joinResult) {
          if (isOutbound) {
            if (!hasTrackedCall(callSid)) {
              return {
                provider: 'fonoster',
                joinSupported: false,
                reason: 'call_closed',
                callSid,
              };
            }

            return failFonosterOutboundWithoutInvite(callSid);
          }

          return {
            provider: 'fonoster',
            joinSupported: false,
            reason: 'sip_invite_not_received',
          };
        }

        if (isOutbound) {
          callsStore.markBrowserJoined(callSid, 'fonoster');
          return {
            provider: 'fonoster',
            joinSupported: true,
            waitingForAnswer: true,
          };
        }

        callsStore.setCallActive(callSid);

        return {
          provider: 'fonoster',
          joinSupported: true,
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

    if (provider === 'fonoster') {
      if (isOutboundCallDirection(call?.callDirection)) {
        return cancelFonosterOutboundCall(call);
      }

      const releaseResult = await runOnceForCall(
        releasingCallSids,
        call?.callSid,
        async () => {
          try {
            await WebphoneClient.rejectIncomingCall(provider);
          } catch (error) {
            // eslint-disable-next-line no-console
            console.warn('Failed to decline Fonoster browser call:', error);
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
