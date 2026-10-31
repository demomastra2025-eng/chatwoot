import { computed, nextTick, onMounted } from 'vue';
import { emitter } from 'shared/helpers/mitt';
import { useWhatsappCallsStore } from 'dashboard/stores/whatsappCalls';
import WhatsappCallsAPI from 'dashboard/api/whatsappCalls';
import TelegramPersonalCallsAPI, {
  callsApiFor,
} from 'dashboard/api/telegramPersonalCalls';
import { handleAgentOffer } from 'dashboard/composables/useWhatsappCallSession';

async function fetchActiveCallForApi(api, defaultProvider) {
  try {
    const { data } = await api.active();
    const candidate = data?.call || data;
    if (
      candidate?.id &&
      (!candidate.status || candidate.status === 'in_progress')
    ) {
      return {
        call: candidate,
        provider: candidate.provider || defaultProvider,
      };
    }
  } catch {
    // Endpoint may return 402/404 when feature flag is disabled on this account.
  }
  return null;
}

/**
 * Checks for an active WhatsApp or Telegram Personal call on page load and
 * reconnects if found. Each provider is probed independently so a 402 on
 * WhatsApp Calling never blocks Telegram Personal call reconnection.
 */
export function useCallReconnection() {
  const callsStore = useWhatsappCallsStore();

  const isReconnecting = computed(() => callsStore.isReconnecting);

  const hasAccountScopedRoute = () =>
    /^\/app\/accounts\/[^/]+(?:\/|$)/.test(window.location.pathname);

  const reconnectActiveCall = async () => {
    if (!hasAccountScopedRoute()) return;
    if (callsStore.hasActiveCall || callsStore.hasIncomingCall) return;

    try {
      const found =
        (await fetchActiveCallForApi(WhatsappCallsAPI, 'whatsapp')) ||
        (await fetchActiveCallForApi(
          TelegramPersonalCallsAPI,
          'telegram_personal'
        ));
      if (!found) return;

      const { call: activeCallData, provider: resolvedProvider } = found;

      callsStore.setReconnecting(true);
      callsStore.setActiveCall({
        id: activeCallData.id,
        callId: activeCallData.call_id,
        provider: resolvedProvider,
        direction: activeCallData.direction,
        conversationId: activeCallData.conversation_id,
        status: 'reconnecting',
        serverRelay: true,
        caller: activeCallData.caller,
      });

      if (activeCallData.elapsed_seconds) {
        callsStore.setTimerOffset(activeCallData.elapsed_seconds);
      }

      await nextTick();

      const { data: reconnectData } = await callsApiFor(
        resolvedProvider
      ).reconnect(activeCallData.id);
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
          peerId: reconnectData.peer_id,
          provider: resolvedProvider,
        }
      );
      callsStore.markActiveCallConnected();
      emitter.emit('whatsapp_call:agent_webrtc_connected');
    } catch {
      callsStore.clearActiveCall();
    } finally {
      callsStore.setReconnecting(false);
    }
  };

  onMounted(reconnectActiveCall);

  return { isReconnecting, reconnectActiveCall };
}
