import { computed, ref, watch, onUnmounted, onMounted } from 'vue';
import VoiceAPI from 'dashboard/api/channel/voice/voiceAPIClient';
import WebphoneClient from 'dashboard/api/channel/voice/webphoneClient';
import { useCallsStore } from 'dashboard/stores/calls';
import Timer from 'dashboard/helper/Timer';

export function useCallSession() {
  const callsStore = useCallsStore();
  const isJoining = ref(false);
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

  const endCall = async ({ conversationId, inboxId, provider }) => {
    if (provider !== 'fonoster') {
      await VoiceAPI.leaveConference(inboxId, conversationId);
    }

    await WebphoneClient.endClientCall(provider);
    durationTimer.stop();
    callsStore.clearActiveCall();
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
        const joinResult = await WebphoneClient.joinClientCall({
          provider: 'fonoster',
          conversationId,
          callRef: callSid,
        });

        if (!joinResult) {
          callsStore.markBrowserJoinUnsupported(callSid, 'fonoster');
          return {
            provider: 'fonoster',
            joinSupported: false,
          };
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
      await WebphoneClient.rejectIncomingCall(provider);
    } else {
      await WebphoneClient.endClientCall(provider);
    }

    callsStore.dismissCall(call?.callSid);
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
