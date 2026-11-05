import { computed, ref, unref, watch } from 'vue';
import { useStore } from 'vuex';
import { useI18n } from 'vue-i18n';

import WhatsappCallsAPI from 'dashboard/api/whatsappCalls';
import {
  callsApiFor,
  isTelegramPersonalProvider,
} from 'dashboard/api/telegramPersonalCalls';
import { BUS_EVENTS } from 'shared/constants/busEvents';
import { emitter } from 'shared/helpers/mitt';
import { INBOX_TYPES } from 'dashboard/helper/inbox';
import { getCommunicationReplyInboxId } from 'dashboard/helper/communicationThreadHelper';
import {
  useWhatsappCallsStore,
  setOutboundCallProperty,
} from 'dashboard/stores/whatsappCalls';
import {
  handleAgentOffer,
  handleCallAgentOffer,
  hasAgentMediaOffer,
  handleMediaLegClosed,
  isMediaLegClosedError,
} from 'dashboard/composables/useWhatsappCallSession';

const OUTBOUND_ICE_GATHERING_TIMEOUT = 10000;

const waitForOutboundIceGathering = pc =>
  new Promise((resolve, reject) => {
    if (pc.iceGatheringState === 'complete') {
      resolve();
      return;
    }

    let timeout = null;

    const cleanup = () => {
      clearTimeout(timeout);
      pc.onicegatheringstatechange = null;
      pc.oniceconnectionstatechange = null;
    };

    timeout = setTimeout(() => {
      cleanup();
      resolve();
    }, OUTBOUND_ICE_GATHERING_TIMEOUT);

    pc.onicegatheringstatechange = () => {
      if (pc.iceGatheringState === 'complete') {
        cleanup();
        resolve();
      }
    };
    pc.oniceconnectionstatechange = () => {
      if (pc.iceConnectionState === 'failed') {
        cleanup();
        reject(new Error('ICE connection failed'));
      }
    };
  });

export const useWhatsappCallInitiation = (options = {}) => {
  const { t } = useI18n();
  const store = useStore();
  const whatsappCallsStore = useWhatsappCallsStore();
  const isInitiatingCall = ref(false);

  const currentChat = computed(() => store?.getters?.getSelectedChat || {});
  const selectedConversationId = computed(
    () => unref(options.conversationId) || currentChat.value?.id
  );
  const selectedInboxId = computed(
    () =>
      unref(options.inboxId) || getCommunicationReplyInboxId(currentChat.value)
  );
  const selectedChannel = computed(() => unref(options.channel) || {});
  const inbox = computed(() => {
    const inboxId = selectedInboxId.value;
    return inboxId ? store.getters['inboxes/getInbox'](inboxId) : null;
  });
  const currentContact = computed(() => {
    const optionContact = unref(options.contact);
    if (optionContact?.id) return optionContact;

    const senderId = currentChat.value?.meta?.sender?.id;
    return senderId ? store.getters['contacts/getContact'](senderId) : {};
  });
  let targetGeneration = 0;
  watch(
    [
      () => store?.getters?.getCurrentAccountId,
      selectedInboxId,
      selectedConversationId,
    ],
    () => {
      targetGeneration += 1;
    },
    { flush: 'sync' }
  );
  const capturePreparation = () => ({
    callGeneration: whatsappCallsStore.activeCallGeneration,
    targetGeneration,
    accountId: store?.getters?.getCurrentAccountId,
  });
  const samePreparationAccount = scope =>
    scope.accountId === store?.getters?.getCurrentAccountId;
  const samePreparationTarget = scope =>
    samePreparationAccount(scope) &&
    scope.targetGeneration === targetGeneration;
  const isAWhatsAppCloudChannel = computed(() => {
    return (
      (inbox.value?.channel_type === INBOX_TYPES.WHATSAPP &&
        inbox.value?.provider === 'whatsapp_cloud') ||
      (selectedChannel.value?.can_call === true &&
        selectedChannel.value?.channel !== INBOX_TYPES.TELEGRAM_PERSONAL)
    );
  });
  const isATelegramPersonalChannel = computed(() => {
    return (
      inbox.value?.channel_type === INBOX_TYPES.TELEGRAM_PERSONAL ||
      selectedChannel.value?.channel === INBOX_TYPES.TELEGRAM_PERSONAL
    );
  });
  const targetConversation = computed(() => {
    const convId = selectedConversationId.value;
    return (
      unref(options.conversation) ||
      (convId && store.getters.getConversationById?.(convId)) ||
      currentChat.value ||
      {}
    );
  });
  const isTelegramGroupChat = computed(() => {
    const conv = targetConversation.value;
    const attrs =
      conv?.additional_attributes ||
      currentChat.value?.additional_attributes ||
      {};
    if (attrs.is_group === true) return true;
    if (['group', 'supergroup', 'channel'].includes(attrs.chat_type)) {
      return true;
    }
    const rawId =
      attrs.chat_id ||
      attrs.peer_user_id ||
      conv?.meta?.sender?.identifier ||
      '';
    return String(rawId).startsWith('-');
  });
  const callProvider = computed(() =>
    isATelegramPersonalChannel.value ? 'telegram_personal' : 'whatsapp'
  );
  const callingEnabled = computed(() => {
    const optionCallingEnabled = unref(options.callingEnabled);
    if (optionCallingEnabled !== undefined) {
      return Boolean(optionCallingEnabled);
    }

    return Boolean(inbox.value?.calling_enabled);
  });

  const canInitiateWhatsappCall = computed(() => {
    const isCallableChannel =
      isAWhatsAppCloudChannel.value ||
      (isATelegramPersonalChannel.value && !isTelegramGroupChat.value);
    if (!isCallableChannel) return false;
    if (!callingEnabled.value) return false;
    if (whatsappCallsStore.hasWhatsappCall) return false;
    return true;
  });

  const isMediaServerEnabled = computed(() => {
    if (isATelegramPersonalChannel.value) return true;
    const optionMediaServerEnabled = unref(options.mediaServerEnabled);
    if (optionMediaServerEnabled !== undefined) {
      return Boolean(optionMediaServerEnabled);
    }

    return Boolean(inbox.value?.media_server_enabled);
  });

  const showPermissionStatusAlert = callStatus => {
    const message =
      callStatus === 'permission_requested'
        ? t('WHATSAPP_CALL.PERMISSION_REQUESTED')
        : t('WHATSAPP_CALL.PERMISSION_PENDING');
    emitter.emit(BUS_EVENTS.SHOW_ALERT, { message, type: 'info' });
  };

  const connectImmediateOutboundAgentOffer = async (
    callId,
    agentOffer,
    provider
  ) => {
    if (!hasAgentMediaOffer(agentOffer)) return false;

    const callScope = whatsappCallsStore.captureActiveCallScope();
    whatsappCallsStore.updateActiveCall({ agentWebrtcConnecting: true });
    try {
      const mediaOptions = {
        direction: 'outbound',
        context: 'outbound-initiate-response',
        peerId: agentOffer.peer_id,
        provider,
      };
      if (isTelegramPersonalProvider(provider)) {
        await handleCallAgentOffer(callId, agentOffer, mediaOptions);
      } else {
        await handleAgentOffer(
          callId,
          agentOffer.sdp_offer,
          agentOffer.ice_servers,
          mediaOptions
        );
      }
      if (!whatsappCallsStore.matchesActiveCallScope(callScope)) return false;
      whatsappCallsStore.updateActiveCall({
        agentWebrtcConnected: true,
        agentWebrtcConnecting: false,
      });
      if (whatsappCallsStore.activeCall?.metaAccepted) {
        whatsappCallsStore.markActiveCallConnected();
        emitter.emit('whatsapp_call:agent_webrtc_connected');
      }
      return true;
    } catch (err) {
      if (!whatsappCallsStore.matchesActiveCallScope(callScope)) return false;
      whatsappCallsStore.updateActiveCall({ agentWebrtcConnecting: false });
      if (isMediaLegClosedError(err)) {
        handleMediaLegClosed(whatsappCallsStore);
        return false;
      }
      // eslint-disable-next-line no-console
      console.error(
        '[WhatsApp Call] Failed to handle immediate outbound agent offer:',
        err
      );
      return false;
    }
  };

  const ownsOutboundPreparation = generation =>
    whatsappCallsStore.activeCallGeneration === generation.callGeneration &&
    samePreparationTarget(generation) &&
    !whatsappCallsStore.hasWhatsappCall;

  const setOutboundActiveCall = (response, initialGeneration) => {
    if (!ownsOutboundPreparation(initialGeneration)) return null;
    const outboundCallId = response.data?.call_id;
    const username = currentChat.value?.additional_attributes?.username;
    const fallbackHandle = username
      ? `@${String(username).replace(/^@/, '')}`
      : undefined;
    const activeCallData = {
      id: response.data?.id,
      callId: outboundCallId,
      provider: response.data?.provider || callProvider.value,
      direction: 'outbound',
      status: 'ringing',
      serverRelay: isMediaServerEnabled.value,
      conversationId: selectedConversationId.value,
      caller: {
        name: currentContact.value?.name,
        phone: currentContact.value?.phone_number || fallbackHandle,
        avatar: currentContact.value?.thumbnail,
      },
    };
    whatsappCallsStore.setActiveCall(activeCallData);
    return activeCallData;
  };

  const handleInitiatePermissionStatus = response => {
    const callStatus = response.data?.status;
    if (
      callStatus === 'permission_requested' ||
      callStatus === 'permission_pending'
    ) {
      showPermissionStatusAlert(callStatus);
      return true;
    }
    return false;
  };

  const handleInitiateError = err => {
    const permissionStatus = err.response?.data?.status;
    if (
      permissionStatus === 'permission_requested' ||
      permissionStatus === 'permission_pending'
    ) {
      showPermissionStatusAlert(permissionStatus);
      return;
    }

    const errorMessage =
      err.response?.data?.error || t('WHATSAPP_CALL.CALL_FAILED');
    emitter.emit(BUS_EVENTS.SHOW_ALERT, {
      message: errorMessage,
      type: 'error',
    });
  };

  const showCallingAlert = () => {
    emitter.emit(BUS_EVENTS.SHOW_ALERT, {
      message: t('WHATSAPP_CALL.CALLING'),
      type: 'success',
    });
  };

  const initiateServerRelayCall = async () => {
    if (isInitiatingCall.value || !selectedConversationId.value) return;
    isInitiatingCall.value = true;
    const provider = callProvider.value;
    const api = callsApiFor(provider);
    let preparedCallId = null;
    let dialStarted = false;
    let callScope = null;
    const initialGeneration = capturePreparation();

    try {
      showCallingAlert();
      const response = await api.prepareOutbound(selectedConversationId.value);
      if (handleInitiatePermissionStatus(response)) return;
      preparedCallId = response.data?.id;

      const activeCallData = setOutboundActiveCall(response, initialGeneration);
      if (!activeCallData) {
        if (preparedCallId && samePreparationAccount(initialGeneration))
          api.terminate(preparedCallId).catch(() => {});
        return;
      }
      callScope = whatsappCallsStore.captureActiveCallScope();
      const agentOffer =
        response.data?.agent_offer ||
        whatsappCallsStore.consumePendingAgentOffer(activeCallData);
      if (response.data?.agent_offer) {
        whatsappCallsStore.clearPendingAgentOffer(activeCallData);
      }
      const operatorLegReady = await connectImmediateOutboundAgentOffer(
        response.data?.id,
        agentOffer,
        provider
      );
      if (!samePreparationTarget(initialGeneration)) {
        if (whatsappCallsStore.matchesActiveCallScope(callScope)) {
          // Use the session's existing cleanup callback; never touch a newer
          // call generation or send an old call id to the new account URL.
          whatsappCallsStore.handleCallEnded(
            activeCallData.callId,
            preparedCallId
          );
          if (samePreparationAccount(initialGeneration)) {
            api.terminate(preparedCallId).catch(() => {});
          }
        }
        return;
      }
      if (!operatorLegReady) {
        throw new Error(t('WHATSAPP_CALL.CALL_FAILED'));
      }

      if (
        !samePreparationTarget(initialGeneration) ||
        !whatsappCallsStore.matchesActiveCallScope(callScope)
      )
        return;
      dialStarted = true;
      const dialResponse = await api.dial(response.data?.id);
      if (!samePreparationTarget(initialGeneration)) return;
      const currentActive = whatsappCallsStore.activeCall;
      if (!whatsappCallsStore.matchesActiveCallScope(callScope)) return;
      if (handleInitiatePermissionStatus(dialResponse)) {
        whatsappCallsStore.clearActiveCall();
        return;
      }
      const dialStatus = dialResponse.data?.status;
      if (['completed', 'failed', 'no_answer', 'busy'].includes(dialStatus)) {
        whatsappCallsStore.clearActiveCall();
        return;
      }
      const alreadyConnected =
        currentActive.status === 'connected' ||
        currentActive.metaAccepted === true ||
        dialStatus === 'in_progress';
      whatsappCallsStore.updateActiveCall({
        id: dialResponse.data?.id || response.data?.id,
        callId: dialResponse.data?.call_id || currentActive.callId,
        ...(alreadyConnected
          ? { metaAccepted: true, status: 'connected' }
          : { status: dialStatus || 'ringing' }),
      });
      if (alreadyConnected && currentActive.status !== 'connected') {
        whatsappCallsStore.markActiveCallConnected();
        emitter.emit('whatsapp_call:agent_webrtc_connected');
      }
    } catch (err) {
      if (!samePreparationAccount(initialGeneration)) return;
      if (preparedCallId && !dialStarted) {
        api.terminate(preparedCallId).catch(() => {});
      }
      const ownsCall = callScope
        ? whatsappCallsStore.matchesActiveCallScope(callScope)
        : ownsOutboundPreparation(initialGeneration);
      if (!ownsCall) return;
      whatsappCallsStore.clearActiveCall();
      handleInitiateError(err);
    } finally {
      isInitiatingCall.value = false;
    }
  };

  const initiateLegacyCall = async () => {
    if (isInitiatingCall.value || !selectedConversationId.value) return;
    isInitiatingCall.value = true;
    let pc = null;
    let localStream = null;
    const initialGeneration = capturePreparation();
    try {
      localStream = await navigator.mediaDevices.getUserMedia({ audio: true });
      if (!ownsOutboundPreparation(initialGeneration)) {
        localStream.getTracks().forEach(track => track.stop());
        return;
      }
      pc = new RTCPeerConnection({
        iceServers: [{ urls: 'stun:stun.l.google.com:19302' }],
      });
      localStream.getTracks().forEach(track => pc.addTrack(track, localStream));

      pc.ontrack = event => {
        const [stream] = event.streams;
        if (!stream) return;
        const audio = document.createElement('audio');
        audio.srcObject = stream;
        audio.autoplay = true;
        document.body.appendChild(audio);
        setOutboundCallProperty('audio', audio);
      };

      const offer = await pc.createOffer();
      await pc.setLocalDescription(offer);

      await waitForOutboundIceGathering(pc);
      const completeSdp = pc.localDescription.sdp;

      if (!ownsOutboundPreparation(initialGeneration)) {
        pc.close();
        localStream.getTracks().forEach(track => track.stop());
        return;
      }
      const response = await WhatsappCallsAPI.initiate(
        selectedConversationId.value,
        completeSdp
      );

      if (handleInitiatePermissionStatus(response)) {
        pc.close();
        localStream.getTracks().forEach(track => track.stop());
        return;
      }

      if (!setOutboundActiveCall(response, initialGeneration)) {
        pc.close();
        localStream.getTracks().forEach(track => track.stop());
        if (response.data?.id && samePreparationAccount(initialGeneration))
          WhatsappCallsAPI.terminate(response.data.id).catch(() => {});
        return;
      }
      showCallingAlert();
      const outboundCallId = response.data?.call_id;
      setOutboundCallProperty('pc', pc);
      setOutboundCallProperty('stream', localStream);
      setOutboundCallProperty('callId', outboundCallId);
    } catch (err) {
      if (pc) pc.close();
      if (localStream) localStream.getTracks().forEach(track => track.stop());
      handleInitiateError(err);
    } finally {
      isInitiatingCall.value = false;
    }
  };

  const initiateWhatsappCall = () => {
    if (isMediaServerEnabled.value) {
      return initiateServerRelayCall();
    }
    return initiateLegacyCall();
  };

  return {
    canInitiateWhatsappCall,
    initiateWhatsappCall,
    isInitiatingWhatsappCall: isInitiatingCall,
  };
};
