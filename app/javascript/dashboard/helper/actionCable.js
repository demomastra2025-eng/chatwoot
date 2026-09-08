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
import types from 'dashboard/store/mutation-types';
import {
  startFaviconBlinking,
  stopFaviconBlinking,
} from './AudioAlerts/faviconHelper';

let audioNotificationHelperPromise;
const SIDEBAR_UNREAD_COUNTS_REFRESH_DELAY = 1000;
const SIDEBAR_UNREAD_COUNTS_MIN_INTERVAL = 30000;
const SIDEBAR_UNREAD_COUNTS_LOCK_TTL = 15000;
const SIDEBAR_UNREAD_COUNTS_CACHE_TTL = 30000;
const SIDEBAR_UNREAD_COUNTS_STORAGE_PREFIX = 'chatwoot:sidebar-unread-counts';
const SIDEBAR_UNREAD_COUNTS_CONTEXT_KEYS = [
  'inboxId',
  'status',
  'assigneeType',
  'labels',
  'labelsScope',
  'teamId',
  'teamScope',
  'conversationType',
  'communicationThreadMode',
  'crmPipelineId',
  'crmStageId',
  'appointmentStatus',
  'unread',
  'queryData',
];
const CRM_PIPELINES_REFRESH_DELAY = 500;

const stableSerialize = value => {
  if (Array.isArray(value)) return `[${value.map(stableSerialize).join(',')}]`;
  if (value && typeof value === 'object') {
    return `{${Object.keys(value)
      .sort()
      .map(key => `${JSON.stringify(key)}:${stableSerialize(value[key])}`)
      .join(',')}}`;
  }
  return JSON.stringify(value);
};

const stringHash = value => {
  let hash = 5381;
  for (let index = 0; index < value.length; index += 1) {
    hash = (hash * 33 + value.charCodeAt(index)) % 2147483647;
  }
  return hash.toString(36);
};

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

const voiceCallMetadata = data => data?.metadata || data?.route_metadata || {};

const isServerManagedVoiceCall = data => {
  const metadata = voiceCallMetadata(data);
  const callRef = data?.call_ref || data?.callSid || data?.call_sid;
  return (
    metadata.source === 'server_janus_sip' ||
    metadata.server_runtime === true ||
    metadata.serverRuntime === true ||
    data?.server_runtime === true ||
    data?.serverRuntime === true ||
    data?.janus?.server_runtime === true ||
    String(callRef || '').includes(':janus-server:')
  );
};

class ActionCableConnector extends BaseActionCableConnector {
  constructor(app, pubsubToken, authClientId = null) {
    const { websocketURL = '' } = window.chatwootConfig || {};
    super(app, pubsubToken, authClientId, websocketURL);
    this.CancelTyping = [];
    this.sidebarUnreadCountsRefreshTimer = null;
    this.isSidebarUnreadCountsRefreshInFlight = false;
    this.hasQueuedSidebarUnreadCountsRefresh = false;
    this.lastSidebarUnreadCountsRefreshAt = 0;
    this.lastSidebarUnreadCountsRequestedAt = 0;
    this.isDisconnected = false;
    this.sidebarUnreadCountsStorageKey = `${SIDEBAR_UNREAD_COUNTS_STORAGE_PREFIX}:${this.app.$store.getters.getCurrentAccountId}:${this.app.$store.getters.getCurrentUserID}`;
    if (typeof window !== 'undefined') {
      window.addEventListener('storage', this.onSidebarUnreadCountsStorage);
    }
    if (typeof document !== 'undefined') {
      document.addEventListener(
        'visibilitychange',
        this.onSidebarUnreadCountsVisibilityChange
      );
    }
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
      'telephony.webphone_config_changed':
        this.onTelephonyWebphoneConfigChanged,
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
    stopFaviconBlinking();
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
    const communicationThreadMode = Boolean(
      this.app.$store.state?.conversations?.conversationFilters
        ?.communicationThreadMode
    );
    if (!communicationThreadMode) {
      emitter.emit('fetch_conversation_stats');
    }
    this.fetchSidebarUnreadCounts();
  };

  sidebarUnreadCountsContextId = (filters = null) => {
    const currentFilters =
      filters ||
      this.app.$store.state?.conversations?.conversationFilters ||
      {};
    const countContext = Object.fromEntries(
      SIDEBAR_UNREAD_COUNTS_CONTEXT_KEYS.map(key => [key, currentFilters[key]])
    );
    return stringHash(stableSerialize(countContext));
  };

  // eslint-disable-next-line class-methods-use-this
  isSidebarUnreadCountsRefreshVisible = () => {
    return (
      typeof document === 'undefined' || document.visibilityState !== 'hidden'
    );
  };

  onSidebarUnreadCountsVisibilityChange = () => {
    if (
      !this.isDisconnected &&
      this.isSidebarUnreadCountsRefreshVisible() &&
      this.hasQueuedSidebarUnreadCountsRefresh
    ) {
      this.hasQueuedSidebarUnreadCountsRefresh = false;
      this.fetchSidebarUnreadCounts();
    }
  };

  onSidebarUnreadCountsStorage = event => {
    if (
      this.isDisconnected ||
      event.key !== this.sidebarUnreadCountsStorageKey ||
      !event.newValue
    )
      return;

    try {
      const payload = JSON.parse(event.newValue);
      if (payload.contextId !== this.sidebarUnreadCountsContextId()) return;
      const refreshedAt = Number(payload.refreshedAt);
      const requestedAt = Number(payload.requestedAt);
      if (
        !Number.isFinite(refreshedAt) ||
        !Number.isFinite(requestedAt) ||
        Date.now() - refreshedAt > SIDEBAR_UNREAD_COUNTS_CACHE_TTL ||
        requestedAt < this.lastSidebarUnreadCountsRequestedAt ||
        refreshedAt <= this.lastSidebarUnreadCountsRefreshAt
      )
        return;

      this.app.$store.commit?.(
        types.SET_CONVERSATION_SIDEBAR_UNREAD_COUNTS,
        payload.counts || {}
      );
      this.lastSidebarUnreadCountsRequestedAt = requestedAt;
      this.lastSidebarUnreadCountsRefreshAt = refreshedAt;
      this.hasQueuedSidebarUnreadCountsRefresh = false;
      if (this.sidebarUnreadCountsRefreshTimer) {
        clearTimeout(this.sidebarUnreadCountsRefreshTimer);
        this.sidebarUnreadCountsRefreshTimer = null;
      }
    } catch {
      // Ignore malformed or unavailable cross-tab cache data.
    }
  };

  publishSidebarUnreadCounts = (contextId, counts, requestedAt) => {
    if (typeof window === 'undefined' || !window.localStorage) return;

    try {
      window.localStorage.setItem(
        this.sidebarUnreadCountsStorageKey,
        JSON.stringify({
          contextId,
          counts,
          requestedAt,
          refreshedAt: Date.now(),
        })
      );
    } catch {
      // Cross-tab coordination is an optimization; local refresh still works.
    }
  };

  runSidebarUnreadCountsWithStorageLock = async (lockName, callback) => {
    if (typeof window === 'undefined' || !window.localStorage) {
      await callback(() => true);
      return true;
    }

    const lockKey = `${this.sidebarUnreadCountsStorageKey}:lock:${lockName}`;
    await Promise.resolve();
    const now = Date.now();
    const owner = `${now}:${Math.random()}`;
    let acquired = false;
    try {
      const existingLock = JSON.parse(window.localStorage.getItem(lockKey));
      if (existingLock?.expiresAt > now) return false;

      window.localStorage.setItem(
        lockKey,
        JSON.stringify({
          owner,
          expiresAt: now + SIDEBAR_UNREAD_COUNTS_LOCK_TTL,
        })
      );
      const acquiredLock = JSON.parse(window.localStorage.getItem(lockKey));
      if (acquiredLock?.owner !== owner) return false;
      acquired = true;
    } catch {
      await callback(() => true);
      return true;
    }

    let lockLost = false;
    const isLockOwned = () => {
      try {
        const currentLock = JSON.parse(window.localStorage.getItem(lockKey));
        return currentLock?.owner === owner;
      } catch {
        return false;
      }
    };
    const leaseRenewalTimer = setInterval(
      () => {
        if (!isLockOwned()) {
          lockLost = true;
          return;
        }

        try {
          window.localStorage.setItem(
            lockKey,
            JSON.stringify({
              owner,
              expiresAt: Date.now() + SIDEBAR_UNREAD_COUNTS_LOCK_TTL,
            })
          );
        } catch {
          lockLost = true;
        }
      },
      Math.floor(SIDEBAR_UNREAD_COUNTS_LOCK_TTL / 3)
    );

    try {
      await callback(() => acquired && !lockLost && isLockOwned());
      return true;
    } finally {
      clearInterval(leaseRenewalTimer);
      try {
        const currentLock = JSON.parse(window.localStorage.getItem(lockKey));
        if (currentLock?.owner === owner)
          window.localStorage.removeItem(lockKey);
      } catch {
        // Ignore cleanup failures; the lease will expire.
      }
    }
  };

  runSidebarUnreadCountsWithCrossTabLock = async (contextId, callback) => {
    const lockName = `${this.sidebarUnreadCountsStorageKey}:${contextId}`;
    if (typeof navigator !== 'undefined' && navigator.locks?.request) {
      return navigator.locks.request(
        lockName,
        { ifAvailable: true },
        async lock => {
          if (!lock) return false;

          await callback(() => true);
          return true;
        }
      );
    }

    return this.runSidebarUnreadCountsWithStorageLock(lockName, callback);
  };

  fetchSidebarUnreadCounts = () => {
    if (this.isDisconnected) return;
    if (!this.isSidebarUnreadCountsRefreshVisible()) {
      this.hasQueuedSidebarUnreadCountsRefresh = true;
      return;
    }
    if (this.sidebarUnreadCountsRefreshTimer) return;

    if (this.isSidebarUnreadCountsRefreshInFlight) {
      this.hasQueuedSidebarUnreadCountsRefresh = true;
      return;
    }

    const elapsedSinceRefresh = this.lastSidebarUnreadCountsRefreshAt
      ? Date.now() - this.lastSidebarUnreadCountsRefreshAt
      : Number.POSITIVE_INFINITY;
    const refreshDelay = Math.max(
      SIDEBAR_UNREAD_COUNTS_REFRESH_DELAY,
      SIDEBAR_UNREAD_COUNTS_MIN_INTERVAL - elapsedSinceRefresh
    );
    this.sidebarUnreadCountsRefreshTimer = setTimeout(() => {
      this.sidebarUnreadCountsRefreshTimer = null;
      this.dispatchSidebarUnreadCountsRefresh();
    }, refreshDelay);
  };

  dispatchSidebarUnreadCountsRefresh = () => {
    if (this.isDisconnected) return;
    if (!this.isSidebarUnreadCountsRefreshVisible()) {
      this.hasQueuedSidebarUnreadCountsRefresh = true;
      return;
    }

    this.isSidebarUnreadCountsRefreshInFlight = true;
    const filters = {
      ...(this.app.$store.state?.conversations?.conversationFilters || {}),
    };
    const contextId = this.sidebarUnreadCountsContextId(filters);
    const requestedAt = Date.now();
    this.lastSidebarUnreadCountsRequestedAt = requestedAt;
    this.runSidebarUnreadCountsWithCrossTabLock(
      contextId,
      async isLockOwned => {
        if (this.isDisconnected) return;

        const counts = await this.app.$store.dispatch(
          'fetchRealtimeSidebarUnreadCounts',
          filters
        );
        if (this.isDisconnected || (isLockOwned && !isLockOwned())) return;

        this.lastSidebarUnreadCountsRefreshAt = Date.now();
        if (counts !== undefined) {
          this.publishSidebarUnreadCounts(contextId, counts, requestedAt);
        }
      }
    )
      .then(acquired => {
        if (!acquired) this.hasQueuedSidebarUnreadCountsRefresh = true;
      })
      .catch(() => {
        this.hasQueuedSidebarUnreadCountsRefresh = true;
      })
      .finally(() => {
        this.isSidebarUnreadCountsRefreshInFlight = false;
        if (!this.isDisconnected && this.hasQueuedSidebarUnreadCountsRefresh) {
          this.hasQueuedSidebarUnreadCountsRefresh = false;
          this.fetchSidebarUnreadCounts();
        }
      });
  };

  disconnect() {
    this.isDisconnected = true;
    stopFaviconBlinking();
    if (this.sidebarUnreadCountsRefreshTimer) {
      clearTimeout(this.sidebarUnreadCountsRefreshTimer);
      this.sidebarUnreadCountsRefreshTimer = null;
    }
    if (this.crmPipelinesRefreshTimer) {
      clearTimeout(this.crmPipelinesRefreshTimer);
      this.crmPipelinesRefreshTimer = null;
    }
    this.hasQueuedSidebarUnreadCountsRefresh = false;
    this.hasQueuedCrmPipelinesRefresh = false;
    if (typeof window !== 'undefined') {
      window.removeEventListener('storage', this.onSidebarUnreadCountsStorage);
    }
    if (typeof document !== 'undefined') {
      document.removeEventListener(
        'visibilitychange',
        this.onSidebarUnreadCountsVisibilityChange
      );
    }
    super.disconnect();
  }

  fetchCrmPipelines = () => {
    if (this.isDisconnected) return;
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
    if (this.isDisconnected) return;
    this.isCrmPipelinesRefreshInFlight = true;
    Promise.resolve()
      .then(() => useCrmReferencesStore().loadPipelines())
      .catch(() => {})
      .finally(() => {
        this.isCrmPipelinesRefreshInFlight = false;
        if (!this.isDisconnected && this.hasQueuedCrmPipelinesRefresh) {
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
    if (data.inbox_notification_enabled === true) {
      startFaviconBlinking();
    }
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
    const serverManagedVoiceCall = isServerManagedVoiceCall(data);

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
      browserJoinUnsupportedReason: serverManagedVoiceCall
        ? 'AI_AGENT_HANDLING'
        : data.browser_join_unsupported_reason ||
          data.browserJoinUnsupportedReason,
      serverManagedVoiceCall,
    });
  };

  // eslint-disable-next-line class-methods-use-this
  onVoiceCallStatusChanged = data => {
    const serverManagedVoiceCall = isServerManagedVoiceCall(data);

    const callsStore = useCallsStore();
    const currentUserId = this.app.$store.getters.getCurrentUserID;
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
      logicalCallTerminal:
        data.logical_call_terminal ?? data.logicalCallTerminal,
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
      browserJoinUnsupportedReason: serverManagedVoiceCall
        ? 'AI_AGENT_HANDLING'
        : data.browser_join_unsupported_reason ||
          data.browserJoinUnsupportedReason,
      serverManagedVoiceCall,
      currentUserId,
      showCallsHandledByOtherOperators:
        data.show_calls_handled_by_other_operators ??
        data.showCallsHandledByOtherOperators,
    });
  };

  // eslint-disable-next-line class-methods-use-this
  onVoiceCallClaimed = data => {
    const callsStore = useCallsStore();
    const currentUserId = this.app.$store.getters.getCurrentUserID;
    callsStore.handleCallClaimed(data, currentUserId);
  };

  // eslint-disable-next-line class-methods-use-this
  onTelephonyWebphoneConfigChanged = data => {
    emitter.emit(BUS_EVENTS.TELEPHONY_WEBPHONE_CONFIG_CHANGED, data);
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
