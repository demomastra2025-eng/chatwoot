import { computed, ref, watch, onUnmounted, onMounted } from 'vue';
import VoiceAPI from 'dashboard/api/channel/voice/voiceAPIClient';
import WebphoneClient from 'dashboard/api/channel/voice/webphoneClient';
import { useCallsStore } from 'dashboard/stores/calls';
import Timer from 'dashboard/helper/Timer';

export function useCallSession() {
  const callsStore = useCallsStore();
  const isJoining = ref(false);
  const endingCallSids = ref(new Set());
  const releasingCallSids = ref(new Set());
  const callDuration = ref(0);
  const durationTimer = new Timer(elapsed => {
    callDuration.value = elapsed;
  });

  const activeCall = computed(() => callsStore.activeCall);
  const incomingCalls = computed(() => callsStore.incomingCalls);
  const hasActiveCall = computed(() => callsStore.hasActiveCall);
  const handleClientDisconnect = () => callsStore.clearActiveCall();
  const resolveCallProvider = call => call?.provider || null;
  const isFonosterOutboundCall = call =>
    resolveCallProvider(call) === 'fonoster' &&
    call?.callDirection === 'outbound';

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

  onMounted(() => {
    WebphoneClient.addEventListener(
      'call:disconnected',
      handleClientDisconnect
    );

    WebphoneClient.bootstrapIncomingSupport().catch(error => {
      // eslint-disable-next-line no-console
      console.error('Failed to bootstrap browser calling:', error);
    });
  });

  onUnmounted(() => {
    durationTimer.stop();
    WebphoneClient.removeEventListener(
      'call:disconnected',
      handleClientDisconnect
    );
  });

  const claimErrorPayload = error => error?.response?.data || {};

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

  const callReleaseKey = callSid => callSid || Symbol('unknown_call');

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

  const endCall = async ({ conversationId, inboxId, provider, callSid }) => {
    if (provider === 'fonoster') {
      return runOnceForCall(endingCallSids, callSid, async () => {
        try {
          await WebphoneClient.endClientCall(provider);
        } catch (error) {
          // eslint-disable-next-line no-console
          console.warn('Failed to end Fonoster browser call:', error);
        }

        const releaseResult = await releaseFonosterIncomingCall(callSid, {
          status: 'completed',
          reason: 'operator_hangup',
        });
        if (!releaseResult) return null;
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

      if (resolvedProvider === 'fonoster' && callDirection === 'outbound') {
        callsStore.markBrowserJoinUnsupported(callSid, resolvedProvider);
        return {
          provider: resolvedProvider,
          joinSupported: false,
        };
      }

      if (resolvedProvider === 'fonoster') {
        const claimResult = await claimFonosterIncomingCall(callSid);
        if (!claimResult.claimed) {
          callsStore.markBrowserJoinUnsupported(callSid, 'fonoster');
          return {
            provider: 'fonoster',
            joinSupported: false,
            reason: claimResult.reason || claimResult.code,
          };
        }

        let joinResult = null;
        try {
          joinResult = await WebphoneClient.joinClientCall({
            provider: 'fonoster',
            conversationId,
            callRef: callSid,
          });
        } catch (error) {
          // eslint-disable-next-line no-console
          console.warn('Failed to answer Fonoster incoming call:', error);
          return releaseUnsupportedFonosterJoin(callSid, {
            includeReason: true,
          });
        }

        if (!joinResult) {
          if (webphoneSession.registered === true) {
            return {
              provider: 'fonoster',
              joinSupported: false,
              reason: 'sip_invite_not_received',
            };
          }

          return releaseUnsupportedFonosterJoin(callSid);
        }

        callsStore.setCallActive(callSid);
        durationTimer.start();

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
    if (isFonosterOutboundCall(call)) return false;

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
