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
  });

  onUnmounted(() => {
    durationTimer.stop();
    WebphoneClient.removeEventListener(
      'call:disconnected',
      handleClientDisconnect
    );
  });

  const endCall = async ({ conversationId, inboxId }) => {
    await VoiceAPI.leaveConference(inboxId, conversationId);
    WebphoneClient.endClientCall();
    durationTimer.stop();
    callsStore.clearActiveCall();
  };

  const joinCall = async ({ conversationId, inboxId, callSid }) => {
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

  const rejectIncomingCall = callSid => {
    WebphoneClient.endClientCall();
    callsStore.dismissCall(callSid);
  };

  const dismissCall = callSid => {
    callsStore.dismissCall(callSid);
  };

  const formattedCallDuration = computed(() => {
    const minutes = Math.floor(callDuration.value / 60);
    const seconds = callDuration.value % 60;
    return `${minutes.toString().padStart(2, '0')}:${seconds.toString().padStart(2, '0')}`;
  });

  return {
    activeCall,
    incomingCalls,
    hasActiveCall,
    isJoining,
    formattedCallDuration,
    joinCall,
    endCall,
    rejectIncomingCall,
    dismissCall,
  };
}
