import { computed, nextTick, onMounted } from 'vue';
import { emitter } from 'shared/helpers/mitt';
import { useWhatsappCallsStore } from 'dashboard/stores/whatsappCalls';
import WhatsappCallsAPI from 'dashboard/api/whatsappCalls';
import { handleAgentOffer } from 'dashboard/composables/useWhatsappCallSession';

/**
 * Checks for an active WhatsApp call on page load and reconnects if found.
 * This handles the server-relay scenario where the call persists on the media
 * server even after the agent's browser reloads.
 *
 * Usage: call `useCallReconnection()` in the app-level layout component that
 * mounts once on page load.
 */
export function useCallReconnection() {
  const callsStore = useWhatsappCallsStore();

  const isReconnecting = computed(() => callsStore.isReconnecting);

  const reconnectActiveCall = async () => {
    // Skip if there's already an active or incoming call in the store.
    if (callsStore.hasActiveCall || callsStore.hasIncomingCall) return;

    try {
      const { data } = await WhatsappCallsAPI.active();
      const activeCallData = data?.call || data;
      if (!activeCallData?.id) return;

      callsStore.setReconnecting(true);
      callsStore.setActiveCall({
        id: activeCallData.id,
        callId: activeCallData.call_id,
        direction: activeCallData.direction,
        conversationId: activeCallData.conversation_id,
        status: 'reconnecting',
        serverRelay: true,
        caller: activeCallData.caller,
      });

      // Set timer offset so the timer resumes from the correct elapsed time.
      if (activeCallData.elapsed_seconds) {
        callsStore.setTimerOffset(activeCallData.elapsed_seconds);
      }

      // Let the call widget mount with the active call state before negotiating.
      await nextTick();

      const { data: reconnectData } = await WhatsappCallsAPI.reconnect(
        activeCallData.id
      );
      if (!reconnectData?.sdp_offer) {
        throw new Error('Reconnect response missing sdp_offer');
      }

      await handleAgentOffer(
        activeCallData.id,
        reconnectData.sdp_offer,
        reconnectData.ice_servers,
        {
          direction: activeCallData.direction,
          context: 'page-load-reconnect',
        }
      );
      callsStore.markActiveCallConnected();
      emitter.emit('whatsapp_call:agent_webrtc_connected');
    } catch {
      // No active call or API/reconnect error — clear state and silent fail.
      // clearActiveCall() also resets isReconnecting and callTimerOffset.
      callsStore.clearActiveCall();
    } finally {
      callsStore.setReconnecting(false);
    }
  };

  onMounted(reconnectActiveCall);

  return { isReconnecting, reconnectActiveCall };
}
