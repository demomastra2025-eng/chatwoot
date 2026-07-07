import AuthAPI from '../api/auth';
import BaseActionCableConnector from '../../shared/helpers/BaseActionCableConnector';
import { BUS_EVENTS } from 'shared/constants/busEvents';
import { emitter } from 'shared/helpers/mitt';
import { useImpersonation } from 'dashboard/composables/useImpersonation';
import { handleSessionReplaced } from '../store/utils/api';
import {
  useWhatsappCallsStore,
  getOutboundCallState,
} from 'dashboard/stores/whatsappCalls';
import { useCallsStore } from 'dashboard/stores/calls';
import { useCrmReferencesStore } from 'dashboard/stores/crm/references';
import {
  clearPreparedInboundAgentAnswer,
  handleAgentOffer,
  handleMediaLegClosed,
  isMediaLegClosedError,
  prewarmInboundAgentAnswerForCall,
  startCallRecording,
} from 'dashboard/composables/useWhatsappCallSession';
import WhatsappCallsAPI from 'dashboard/api/whatsappCalls';

let audioNotificationHelperPromise;
const SIDEBAR_UNREAD_COUNTS_REFRESH_DELAY = 250;
const CRM_PIPELINES_REFRESH_DELAY = 500;

const getAudioNotificationHelper = () => {
  audioNotificationHelperPromise ||= import(
    './AudioAlerts/DashboardAudioNotificationHelper'
  ).then(
    ({ default: DashboardAudioNotificationHelper }) =>
      DashboardAudioNotificationHelper
  );
  return audioNotificationHelperPromise;
};

const notifyAudioOnNewMessage = data => {
  getAudioNotificationHelper()
    .then(DashboardAudioNotificationHelper => {
      DashboardAudioNotificationHelper.onNewMessage(data);
    })
    .catch(() => {});
};

const { isImpersonating } = useImpersonation();

class ActionCableConnector extends BaseActionCableConnector {
  constructor(app, pubsubToken, authClientId = null) {
    const { websocketURL = '' } = window.chatwootConfig || {};
    super(app, pubsubToken, authClientId, websocketURL);
    this.CancelTyping = [];
    this.sidebarUnreadCountsRefreshTimer = null;
    this.isSidebarUnreadCountsRefreshInFlight = false;
    this.hasQueuedSidebarUnreadCountsRefresh = false;
    this.crmPipelinesRefreshTimer = null;
    this.isCrmPipelinesRefreshInFlight = false;
    this.hasQueuedCrmPipelinesRefresh = false;
    this.events = {
      'message.created': this.onMessageCreated,
      'message.updated': this.onMessageUpdated,
      'conversation.created': this.onConversationCreated,
      'conversation.status_changed': this.onStatusChange,
      'user:logout': this.onLogout,
      'page:reload': this.onReload,
      'assignee.changed': this.onAssigneeChanged,
      'conversation.typing_on': this.onTypingOn,
      'conversation.typing_off': this.onTypingOff,
      'conversation.contact_changed': this.onConversationContactChange,
      'presence.update': this.onPresenceUpdate,
      'contact.deleted': this.onContactDelete,
      'contact.updated': this.onContactUpdate,
      'conversation.mentioned': this.onConversationMentioned,
      'notification.created': this.onNotificationCreated,
      'notification.deleted': this.onNotificationDeleted,
      'notification.updated': this.onNotificationUpdated,
      'conversation.read': this.onConversationRead,
      'conversation.updated': this.onConversationUpdated,
      'communication_thread.updated': this.onCommunicationThreadUpdated,
      'account.cache_invalidated': this.onCacheInvalidate,
      'copilot.message.created': this.onCopilotMessageCreated,
      'auth.session_replaced': this.onSessionReplaced,
      'voice_call.incoming': this.onVoiceCallIncoming,
      'voice_call.status_changed': this.onVoiceCallStatusChanged,
      'voice_call.claimed': this.onVoiceCallClaimed,
      'whatsapp_call.incoming': this.onWhatsappCallIncoming,
      'whatsapp_call.accepted': this.onWhatsappCallAccepted,
      'whatsapp_call.ended': this.onWhatsappCallEnded,
      'whatsapp_call.outbound_connected': this.onWhatsappCallOutboundConnected,
      'whatsapp_call.outbound_accepted': this.onWhatsappCallOutboundAccepted,
      'whatsapp_call.permission_granted': this.onWhatsappCallPermissionGranted,
      'whatsapp_call.agent_offer': this.onWhatsappCallAgentOffer,
      'whatsapp_call.agent_disconnected': this.onWhatsappCallAgentDisconnected,
      'crm.deal.created': data =>
        this.onCrmDealRealtimeEvent('crm.deal.created', data),
      'crm.deal.updated': data =>
        this.onCrmDealRealtimeEvent('crm.deal.updated', data),
      'crm.deal.stage_changed': data =>
        this.onCrmDealRealtimeEvent('crm.deal.stage_changed', data),
      'crm.deal.archived': data =>
        this.onCrmDealRealtimeEvent('crm.deal.archived', data),
      'crm.deal.unarchived': data =>
        this.onCrmDealRealtimeEvent('crm.deal.unarchived', data),
    };
  }

  // eslint-disable-next-line class-methods-use-this
  onReconnect = () => {
    emitter.emit(BUS_EVENTS.WEBSOCKET_RECONNECT);
  };

  // eslint-disable-next-line class-methods-use-this
  onDisconnected = () => {
    emitter.emit(BUS_EVENTS.WEBSOCKET_DISCONNECT);
  };

  isAValidEvent = (data, event) => {
    if (event === 'auth.session_replaced') {
      return true;
    }

    const eventData = data || {};
    const globalEvents = ['user:logout', 'page:reload'];
    if (globalEvents.includes(event)) return true;
    if (eventData.account_id === undefined || eventData.account_id === null)
      return false;

    return (
      String(this.app.$store.getters.getCurrentAccountId) ===
      String(eventData.account_id)
    );
  };

  // eslint-disable-next-line class-methods-use-this
  onSessionReplaced = data => {
    handleSessionReplaced(data);
  };

  onCrmDealRealtimeEvent = (event, data) => {
    emitter.emit(BUS_EVENTS.CRM_DEAL_REALTIME_EVENT, { event, ...data });
    this.fetchSidebarUnreadCounts();
    this.fetchCrmPipelines();
  };

  onMessageUpdated = data => {
    this.app.$store.dispatch('updateMessage', data);
  };

  onPresenceUpdate = data => {
    if (isImpersonating.value) return;
    this.app.$store.dispatch('contacts/updatePresence', data.contacts);
    this.app.$store.dispatch('agents/updatePresence', data.users);
    this.app.$store.dispatch('setCurrentUserAvailability', data.users);
  };

  onConversationContactChange = payload => {
    const { meta = {}, id: conversationId } = payload;
    const { sender } = meta || {};
    if (conversationId) {
      this.app.$store.dispatch('updateConversationContact', {
        conversationId,
        ...sender,
      });
    }
  };

  onAssigneeChanged = payload => {
    const { id } = payload;
    if (id) {
      this.app.$store.dispatch('updateConversation', payload);
    }
    this.fetchConversationStats();
  };

  onConversationCreated = data => {
    this.app.$store.dispatch('addConversation', data);
    this.fetchConversationStats();
  };

  onConversationRead = data => {
    this.app.$store.dispatch('updateConversation', data);
    this.fetchSidebarUnreadCounts();
  };

  // eslint-disable-next-line class-methods-use-this
  onLogout = () => AuthAPI.logout();

  onMessageCreated = data => {
    const {
      conversation: { last_activity_at: lastActivityAt },
      conversation_id: conversationId,
    } = data;
    notifyAudioOnNewMessage(data);
    this.app.$store.dispatch('addMessage', data);
    this.app.$store.dispatch('updateConversationLastActivity', {
      lastActivityAt,
      conversationId,
    });
    this.fetchSidebarUnreadCounts();
  };

  // eslint-disable-next-line class-methods-use-this
  onReload = () => window.location.reload();

  onStatusChange = data => {
    this.app.$store.dispatch('updateConversation', data);
    this.fetchConversationStats();
  };

  onConversationUpdated = data => {
    this.app.$store.dispatch('updateConversation', data);
    this.fetchConversationStats();
  };

  onCommunicationThreadUpdated = data => {
    this.app.$store.dispatch('updateCommunicationThreadRealtime', data);
    this.fetchConversationStats();
  };

  onTypingOn = ({ conversation, user }) => {
    const conversationId = conversation.id;

    this.clearTimer(conversationId);
    this.app.$store.dispatch('conversationTypingStatus/create', {
      conversationId,
      user,
    });
    this.initTimer({ conversation, user });
  };

  onTypingOff = ({ conversation, user }) => {
    const conversationId = conversation.id;

    this.clearTimer(conversationId);
    this.app.$store.dispatch('conversationTypingStatus/destroy', {
      conversationId,
      user,
    });
  };

  onConversationMentioned = data => {
    this.app.$store.dispatch('addMentions', data);
  };

  clearTimer = conversationId => {
    const timerEvent = this.CancelTyping[conversationId];

    if (timerEvent) {
      clearTimeout(timerEvent);
      this.CancelTyping[conversationId] = null;
    }
  };

  initTimer = ({ conversation, user }) => {
    const conversationId = conversation.id;
    const timeoutMs = user.type === 'captain_assistant' ? 120000 : 30000;

    this.CancelTyping[conversationId] = setTimeout(() => {
      this.onTypingOff({ conversation, user });
    }, timeoutMs);
  };

  fetchConversationStats = () => {
    emitter.emit('fetch_conversation_stats');
    this.fetchSidebarUnreadCounts();
  };

  fetchSidebarUnreadCounts = () => {
    if (this.sidebarUnreadCountsRefreshTimer) return;

    if (this.isSidebarUnreadCountsRefreshInFlight) {
      this.hasQueuedSidebarUnreadCountsRefresh = true;
      return;
    }

    this.sidebarUnreadCountsRefreshTimer = setTimeout(() => {
      this.sidebarUnreadCountsRefreshTimer = null;
      this.dispatchSidebarUnreadCountsRefresh();
    }, SIDEBAR_UNREAD_COUNTS_REFRESH_DELAY);
  };

  dispatchSidebarUnreadCountsRefresh = () => {
    this.isSidebarUnreadCountsRefreshInFlight = true;
    Promise.resolve()
      .then(() => this.app.$store.dispatch('fetchSidebarUnreadCounts'))
      .finally(() => {
        this.isSidebarUnreadCountsRefreshInFlight = false;
        if (this.hasQueuedSidebarUnreadCountsRefresh) {
          this.hasQueuedSidebarUnreadCountsRefresh = false;
          this.fetchSidebarUnreadCounts();
        }
      });
  };

  fetchCrmPipelines = () => {
    if (this.crmPipelinesRefreshTimer) return;

    if (this.isCrmPipelinesRefreshInFlight) {
      this.hasQueuedCrmPipelinesRefresh = true;
      return;
    }

    this.crmPipelinesRefreshTimer = setTimeout(() => {
      this.crmPipelinesRefreshTimer = null;
      this.dispatchCrmPipelinesRefresh();
    }, CRM_PIPELINES_REFRESH_DELAY);
  };

  dispatchCrmPipelinesRefresh = () => {
    this.isCrmPipelinesRefreshInFlight = true;
    Promise.resolve()
      .then(() => useCrmReferencesStore().loadPipelines())
      .catch(() => {})
      .finally(() => {
        this.isCrmPipelinesRefreshInFlight = false;
        if (this.hasQueuedCrmPipelinesRefresh) {
          this.hasQueuedCrmPipelinesRefresh = false;
          this.fetchCrmPipelines();
        }
      });
  };

  onContactDelete = data => {
    this.app.$store.dispatch(
      'contacts/deleteContactThroughConversations',
      data.id
    );
    this.fetchConversationStats();
  };

  onContactUpdate = data => {
    this.app.$store.dispatch('contacts/updateContact', data);
    this.app.$store.dispatch('updateContactInConversations', data);
  };

  onNotificationCreated = data => {
    this.app.$store.dispatch('notifications/addNotification', data);
  };

  onNotificationDeleted = data => {
    this.app.$store.dispatch('notifications/deleteNotification', data);
  };

  onNotificationUpdated = data => {
    this.app.$store.dispatch('notifications/updateNotification', data);
  };

  onCopilotMessageCreated = data => {
    this.app.$store.dispatch('copilotMessages/upsert', data);
  };

  onCacheInvalidate = data => {
    const keys = data.cache_keys;
    this.app.$store.dispatch('labels/revalidate', { newKey: keys.label });
    this.app.$store.dispatch('inboxes/revalidate', { newKey: keys.inbox });
    this.app.$store.dispatch('teams/revalidate', { newKey: keys.team });
  };

  // eslint-disable-next-line class-methods-use-this
  onVoiceCallIncoming = data => {
    const callsStore = useCallsStore();
    callsStore.addCall({
      callSid: data.call_sid || data.callSid || data.call_ref,
      accountId: data.account_id || data.accountId,
      status: data.status || 'ringing',
      startedAt: data.started_at || data.startedAt,
      answeredAt: data.answered_at || data.answeredAt,
      callDirection: data.call_direction || data.direction || 'inbound',
      conversationId: data.conversation_id || data.conversation_display_id,
      conversationDisplayId:
        data.conversation_display_id || data.conversation_id,
      conversationDbId: data.conversation_db_id || data.conversationDbId,
      communicationThreadId:
        data.communication_thread_id || data.communicationThreadId,
      inboxId: data.inbox_id,
      numberRef: data.number_ref || data.numberRef,
      logicalCallKey:
        data.logical_call_key ||
        data.logicalCallKey ||
        data.call_group_key ||
        data.callGroupKey,
      provider: data.provider,
      contactId: data.contact_id || data.contactId,
      senderId: data.sender_id,
      caller: data.caller,
      fromNumber: data.from_number || data.fromNumber,
      toNumber: data.to_number || data.toNumber,
      operatorClaim: data.operator_claim || data.operatorClaim || null,
      operatorCandidates:
        data.operator_candidates || data.operatorCandidates || null,
      operatorInternalExtension:
        data.operator_internal_extension || data.operatorInternalExtension,
      sipProfileId: data.sip_profile_id || data.sipProfileId,
      janusCallRef: data.janus_call_ref || data.janusCallRef,
      janusSessionKey: data.janus_session_key || data.janusSessionKey,
      sipuniNativeWebphoneCorrelation:
        data.sipuni_native_webphone_correlation ??
        data.sipuniNativeWebphoneCorrelation,
      browserJoinSupported:
        data.browser_join_supported ?? data.browserJoinSupported,
    });
  };

  // eslint-disable-next-line class-methods-use-this
  onVoiceCallStatusChanged = data => {
    const callsStore = useCallsStore();
    callsStore.handleCallStatusChanged({
      callSid: data.call_sid || data.callSid || data.call_ref,
      accountId: data.account_id || data.accountId,
      status: data.status,
      startedAt: data.started_at || data.startedAt,
      answeredAt: data.answered_at || data.answeredAt,
      callDirection: data.call_direction || data.direction,
      conversationId: data.conversation_id || data.conversation_display_id,
      conversationDisplayId:
        data.conversation_display_id || data.conversation_id,
      conversationDbId: data.conversation_db_id || data.conversationDbId,
      communicationThreadId:
        data.communication_thread_id || data.communicationThreadId,
      inboxId: data.inbox_id,
      numberRef: data.number_ref || data.numberRef,
      logicalCallKey:
        data.logical_call_key ||
        data.logicalCallKey ||
        data.call_group_key ||
        data.callGroupKey,
      provider: data.provider,
      contactId: data.contact_id || data.contactId,
      senderId: data.sender_id,
      caller: data.caller,
      fromNumber: data.from_number || data.fromNumber,
      toNumber: data.to_number || data.toNumber,
      operatorClaim: data.operator_claim || data.operatorClaim || null,
      operatorCandidates:
        data.operator_candidates || data.operatorCandidates || null,
      operatorInternalExtension:
        data.operator_internal_extension || data.operatorInternalExtension,
      sipProfileId: data.sip_profile_id || data.sipProfileId,
      janusCallRef: data.janus_call_ref || data.janusCallRef,
      janusSessionKey: data.janus_session_key || data.janusSessionKey,
      sipuniNativeWebphoneCorrelation:
        data.sipuni_native_webphone_correlation ??
        data.sipuniNativeWebphoneCorrelation,
      browserJoinSupported:
        data.browser_join_supported ?? data.browserJoinSupported,
    });
  };

  // eslint-disable-next-line class-methods-use-this
  onVoiceCallClaimed = data => {
    const callsStore = useCallsStore();
    const currentUserId = this.app.$store.getters.getCurrentUserID;
    callsStore.handleCallClaimed(data, currentUserId);
  };

  // eslint-disable-next-line class-methods-use-this
  onWhatsappCallIncoming = data => {
    const whatsappCallsStore = useWhatsappCallsStore();
    const currentUserId = this.app.$store.getters.getCurrentUserID;
    // In server-relay mode, sdp_offer and ice_servers are absent — the media
    // server handles WebRTC with Meta, and the browser only needs call metadata.
    const incomingCall = {
      id: data.id,
      callId: data.call_id,
      direction: data.direction,
      inboxId: data.inbox_id,
      conversationId: data.conversation_id,
      conversationDisplayId: data.conversation_display_id,
      communicationThreadId:
        data.communication_thread_id || data.communicationThreadId,
      caller: data.caller,
      sdpOffer: data.sdp_offer || null,
      iceServers: data.ice_servers || null,
      agentOffer:
        data.agent_offer || data.agent_offers?.[String(currentUserId)] || null,
      mediaServerEnabled: data.media_server_enabled,
      mediaSessionId: data.media_session_id || null,
    };
    whatsappCallsStore.addIncomingCall(incomingCall);
    prewarmInboundAgentAnswerForCall(incomingCall)?.catch(err => {
      if (err?.cancelled) return;
      // eslint-disable-next-line no-console
      console.warn(
        '[WhatsApp Call] Failed to prewarm inbound agent answer:',
        err
      );
    });
  };

  onWhatsappCallAccepted = data => {
    const whatsappCallsStore = useWhatsappCallsStore();
    const currentUserId = this.app.$store.getters.getCurrentUserID;
    // If accepted by a different agent, remove from incoming list for this agent
    if (data.accepted_by_agent_id !== currentUserId) {
      whatsappCallsStore.handleCallAcceptedByOther(data.call_id);
      clearPreparedInboundAgentAnswer(data, {
        cleanupWebrtc: this.shouldCleanupPreparedInboundWebRTC(
          whatsappCallsStore,
          data
        ),
      });
    }
  };

  // eslint-disable-next-line class-methods-use-this
  onWhatsappCallEnded = data => {
    const whatsappCallsStore = useWhatsappCallsStore();
    whatsappCallsStore.handleCallEnded(data.call_id);
    clearPreparedInboundAgentAnswer(data, {
      cleanupWebrtc: this.shouldCleanupPreparedInboundWebRTC(
        whatsappCallsStore,
        data
      ),
    });
  };

  // eslint-disable-next-line class-methods-use-this
  shouldCleanupPreparedInboundWebRTC(whatsappCallsStore, data) {
    const activeCall = whatsappCallsStore.activeCall;
    if (!activeCall) return true;
    return activeCall.id === data.id || activeCall.callId === data.call_id;
  }

  // eslint-disable-next-line class-methods-use-this
  onWhatsappCallOutboundConnected = data => {
    const whatsappCallsStore = useWhatsappCallsStore();

    // Server-relay mode: data contains sdp_offer (media server generated offer
    // for Peer B) instead of sdp_answer.
    if (data.sdp_offer) {
      const activeCall = whatsappCallsStore.activeCall;
      if (!activeCall || String(activeCall.callId) !== String(data.call_id)) {
        whatsappCallsStore.storePendingAgentOffer(data);
        return;
      }
      if (
        !activeCall.agentWebrtcConnected &&
        !activeCall.agentWebrtcConnecting
      ) {
        whatsappCallsStore.updateActiveCall({ agentWebrtcConnecting: true });
        handleAgentOffer(activeCall.id, data.sdp_offer, data.ice_servers, {
          direction: 'outbound',
          context: 'outbound-connected',
          peerId: data.peer_id,
        })
          .then(() => {
            whatsappCallsStore.updateActiveCall({
              agentWebrtcConnected: true,
              agentWebrtcConnecting: false,
            });
            if (whatsappCallsStore.activeCall?.metaAccepted) {
              whatsappCallsStore.markActiveCallConnected();
              emitter.emit('whatsapp_call:agent_webrtc_connected');
            }
          })
          .catch(err => {
            whatsappCallsStore.updateActiveCall({
              agentWebrtcConnecting: false,
            });
            if (isMediaLegClosedError(err)) {
              handleMediaLegClosed(whatsappCallsStore);
              return;
            }
            // eslint-disable-next-line no-console
            console.error(
              '[WhatsApp Call] Failed to handle outbound agent offer:',
              err
            );
          });
      }
      return;
    }

    // Legacy mode: data contains sdp_answer (Meta's answer to browser's offer)
    const { pc, callId } = getOutboundCallState();
    if (pc && String(callId) === String(data.call_id) && data.sdp_answer) {
      pc.setRemoteDescription({ type: 'answer', sdp: data.sdp_answer }).catch(
        err => {
          // eslint-disable-next-line no-console
          console.error(
            '[WhatsApp Call] Failed to set remote SDP answer:',
            err
          );
        }
      );
    }
  };

  // eslint-disable-next-line class-methods-use-this
  onWhatsappCallOutboundAccepted = data => {
    const whatsappCallsStore = useWhatsappCallsStore();
    const activeCall = whatsappCallsStore.activeCall;
    if (!activeCall || String(activeCall.callId) !== String(data.call_id)) {
      return;
    }

    if (activeCall.serverRelay) {
      whatsappCallsStore.updateActiveCall({ metaAccepted: true });
      if (!activeCall.agentWebrtcConnected) {
        return;
      }
      whatsappCallsStore.markActiveCallConnected();
      emitter.emit('whatsapp_call:agent_webrtc_connected');
      return;
    }

    if (!activeCall.serverRelay) {
      whatsappCallsStore.markActiveCallConnected();
      const { pc, stream } = getOutboundCallState();
      if (pc && stream) startCallRecording(pc, stream, activeCall.id);
    }

    emitter.emit('whatsapp_call:agent_webrtc_connected');
  };

  // eslint-disable-next-line class-methods-use-this
  onWhatsappCallPermissionGranted = data => {
    emitter.emit('whatsapp_call:permission_granted', {
      contactName: data.contact_name,
    });
  };

  // Server-relay mode: the media server created Peer B and sent an SDP offer
  // for the agent's browser. This fires after POST /accept or POST /reconnect.
  // eslint-disable-next-line class-methods-use-this
  onWhatsappCallAgentOffer = data => {
    const whatsappCallsStore = useWhatsappCallsStore();
    const currentUserId = this.app.$store.getters.getCurrentUserID;
    if (
      data.accepted_by_agent_id &&
      data.accepted_by_agent_id !== currentUserId
    ) {
      return;
    }

    const activeCall = whatsappCallsStore.activeCall;

    if (!activeCall) {
      whatsappCallsStore.storePendingAgentOffer(data);
      return;
    }
    // Verify this offer is for the current active call
    if (
      String(activeCall.callId) !== String(data.call_id) &&
      String(activeCall.id) !== String(data.id)
    ) {
      whatsappCallsStore.storePendingAgentOffer(data);
      return;
    }

    if (activeCall.providerAccepting) {
      whatsappCallsStore.storePendingAgentOffer(data);
      return;
    }

    if (
      (activeCall.agentWebrtcConnected || activeCall.agentWebrtcConnecting) &&
      !whatsappCallsStore.isReconnecting
    ) {
      return;
    }

    whatsappCallsStore.updateActiveCall({ agentWebrtcConnecting: true });
    handleAgentOffer(activeCall.id, data.sdp_offer, data.ice_servers, {
      direction: activeCall.direction,
      context: 'actioncable-agent-offer',
      usePrewarmedStream:
        activeCall.direction === 'incoming' ||
        activeCall.direction === 'inbound',
      peerId: data.peer_id,
    })
      .then(() => {
        whatsappCallsStore.updateActiveCall({
          agentWebrtcConnected: true,
          agentWebrtcConnecting: false,
        });
        whatsappCallsStore.markActiveCallConnected();
        whatsappCallsStore.setReconnecting(false);
        // Emit event so the composable can start the timer
        emitter.emit('whatsapp_call:agent_webrtc_connected');
      })
      .catch(err => {
        whatsappCallsStore.updateActiveCall({ agentWebrtcConnecting: false });
        whatsappCallsStore.setReconnecting(false);
        if (isMediaLegClosedError(err)) {
          handleMediaLegClosed(whatsappCallsStore);
          return;
        }
        // eslint-disable-next-line no-console
        console.error('[WhatsApp Call] Failed to handle agent offer:', err);
      });
  };

  // eslint-disable-next-line class-methods-use-this
  onWhatsappCallAgentDisconnected = async data => {
    const whatsappCallsStore = useWhatsappCallsStore();
    const activeCall = whatsappCallsStore.activeCall;

    if (!activeCall) return;
    if (
      String(activeCall.callId) !== String(data.call_id) &&
      String(activeCall.id) !== String(data.id)
    ) {
      return;
    }

    whatsappCallsStore.setReconnecting(true);
    whatsappCallsStore.updateActiveCall({
      agentWebrtcConnected: false,
      agentWebrtcConnecting: true,
    });

    try {
      const { data: reconnectData } = await WhatsappCallsAPI.reconnect(
        activeCall.id
      );
      if (!reconnectData?.sdp_offer)
        throw new Error('Reconnect response missing sdp_offer');

      await handleAgentOffer(
        activeCall.id,
        reconnectData.sdp_offer,
        reconnectData.ice_servers,
        {
          direction: activeCall.direction || 'unknown',
          context: 'reconnect',
          peerId: reconnectData.peer_id,
        }
      );
      whatsappCallsStore.updateActiveCall({
        agentWebrtcConnected: true,
        agentWebrtcConnecting: false,
      });
      whatsappCallsStore.markActiveCallConnected();
      emitter.emit('whatsapp_call:agent_webrtc_connected');
    } catch (err) {
      whatsappCallsStore.updateActiveCall({ agentWebrtcConnecting: false });
      if (isMediaLegClosedError(err)) {
        handleMediaLegClosed(whatsappCallsStore);
        return;
      }
      // eslint-disable-next-line no-console
      console.error('[WhatsApp Call] Failed to reconnect agent:', err);
    } finally {
      whatsappCallsStore.setReconnecting(false);
    }
  };
}

export default {
  init(store, pubsubToken, authClientId = null) {
    return new ActionCableConnector(
      { $store: store },
      pubsubToken,
      authClientId
    );
  },
};
