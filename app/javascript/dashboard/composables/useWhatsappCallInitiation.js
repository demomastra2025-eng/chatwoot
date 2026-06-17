import { computed, ref, unref } from 'vue';
import { useStore } from 'vuex';
import { useI18n } from 'vue-i18n';

import WhatsappCallsAPI from 'dashboard/api/whatsappCalls';
import { BUS_EVENTS } from 'shared/constants/busEvents';
import { emitter } from 'shared/helpers/mitt';
import { INBOX_TYPES } from 'dashboard/helper/inbox';
import {
  useWhatsappCallsStore,
  setOutboundCallProperty,
} from 'dashboard/stores/whatsappCalls';
import {
  handleAgentOffer,
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

  const currentChat = computed(() => store.getters.getSelectedChat || {});
  const selectedConversationId = computed(
    () => unref(options.conversationId) || currentChat.value?.id
  );
  const selectedInboxId = computed(
    () => unref(options.inboxId) || currentChat.value?.inbox_id
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
  const isAWhatsAppCloudChannel = computed(() => {
    return (
      (inbox.value?.channel_type === INBOX_TYPES.WHATSAPP &&
        inbox.value?.provider === 'whatsapp_cloud') ||
      selectedChannel.value?.can_call === true
    );
  });
  const callingEnabled = computed(() => {
    const optionCallingEnabled = unref(options.callingEnabled);
    if (optionCallingEnabled !== undefined) {
      return Boolean(optionCallingEnabled);
    }

    return Boolean(inbox.value?.calling_enabled);
  });

  const canInitiateWhatsappCall = computed(() => {
    if (!isAWhatsAppCloudChannel.value) return false;
    if (!callingEnabled.value) return false;
    if (whatsappCallsStore.hasWhatsappCall) return false;
    return true;
  });

  const isMediaServerEnabled = computed(() => {
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

  const connectImmediateOutboundAgentOffer = async (callId, agentOffer) => {
    if (!agentOffer?.sdp_offer) return false;

    whatsappCallsStore.updateActiveCall({ agentWebrtcConnecting: true });
    try {
      await handleAgentOffer(
        callId,
        agentOffer.sdp_offer,
        agentOffer.ice_servers,
        {
          direction: 'outbound',
          context: 'outbound-initiate-response',
          peerId: agentOffer.peer_id,
        }
      );
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

  const setOutboundActiveCall = response => {
    const outboundCallId = response.data?.call_id;
    const activeCallData = {
      id: response.data?.id,
      callId: outboundCallId,
      direction: 'outbound',
      status: 'ringing',
      serverRelay: isMediaServerEnabled.value,
      conversationId: selectedConversationId.value,
      caller: {
        name: currentContact.value?.name,
        phone: currentContact.value?.phone_number,
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
    let preparedCallId = null;
    let dialStarted = false;

    try {
      showCallingAlert();
      const response = await WhatsappCallsAPI.prepareOutbound(
        selectedConversationId.value
      );
      if (handleInitiatePermissionStatus(response)) return;
      preparedCallId = response.data?.id;

      const activeCallData = setOutboundActiveCall(response);
      const agentOffer =
        response.data?.agent_offer ||
        whatsappCallsStore.consumePendingAgentOffer(activeCallData);
      if (response.data?.agent_offer) {
        whatsappCallsStore.clearPendingAgentOffer(activeCallData);
      }
      const operatorLegReady = await connectImmediateOutboundAgentOffer(
        response.data?.id,
        agentOffer
      );
      if (!operatorLegReady) {
        throw new Error(t('WHATSAPP_CALL.CALL_FAILED'));
      }

      dialStarted = true;
      const dialResponse = await WhatsappCallsAPI.dial(response.data?.id);
      if (handleInitiatePermissionStatus(dialResponse)) {
        whatsappCallsStore.clearActiveCall();
        return;
      }
      whatsappCallsStore.updateActiveCall({
        id: dialResponse.data?.id || response.data?.id,
        callId: dialResponse.data?.call_id || response.data?.call_id,
        status: dialResponse.data?.status || 'ringing',
      });
    } catch (err) {
      if (preparedCallId && !dialStarted) {
        WhatsappCallsAPI.terminate(preparedCallId).catch(() => {});
      }
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
    try {
      localStream = await navigator.mediaDevices.getUserMedia({ audio: true });
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

      const response = await WhatsappCallsAPI.initiate(
        selectedConversationId.value,
        completeSdp
      );

      if (handleInitiatePermissionStatus(response)) {
        pc.close();
        localStream.getTracks().forEach(track => track.stop());
        return;
      }

      showCallingAlert();
      const outboundCallId = response.data?.call_id;
      setOutboundCallProperty('pc', pc);
      setOutboundCallProperty('stream', localStream);
      setOutboundCallProperty('callId', outboundCallId);
      setOutboundActiveCall(response);
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
