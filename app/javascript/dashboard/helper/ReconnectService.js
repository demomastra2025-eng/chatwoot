import { emitter } from 'shared/helpers/mitt';
import { BUS_EVENTS } from 'shared/constants/busEvents';
import { differenceInSeconds } from 'date-fns';
import { isCommunicationThread } from 'dashboard/helper/communicationThreadHelper';
import {
  isAConversationRoute,
  isAInboxViewRoute,
  isNotificationRoute,
} from 'dashboard/helper/routeHelpers';

const MAX_DISCONNECT_SECONDS = 10800;
const ACTIVE_CONVERSATION_RESYNC_DEBOUNCE = 3000;
const VISIBLE_RECONCILIATION_INTERVAL = 30000;

class ReconnectService {
  constructor(store, router) {
    this.store = store;
    this.router = router;
    this.disconnectTime = null;
    this.lastActiveConversationSyncAt = 0;
    this.isVisibleReconciliationInFlight = false;
    this.visibleReconciliationTimer = null;

    this.setupEventListeners();
    this.startVisibleReconciliation();
  }

  disconnect = () => {
    this.stopVisibleReconciliation();
    this.removeEventListeners();
  };

  startVisibleReconciliation = () => {
    this.stopVisibleReconciliation();
    this.visibleReconciliationTimer = window.setInterval(
      this.reconcileVisibleRoute,
      VISIBLE_RECONCILIATION_INTERVAL
    );
  };

  stopVisibleReconciliation = () => {
    if (!this.visibleReconciliationTimer) return;

    window.clearInterval(this.visibleReconciliationTimer);
    this.visibleReconciliationTimer = null;
  };

  setupEventListeners = () => {
    window.addEventListener('online', this.handleOnlineEvent);
    window.addEventListener('focus', this.handleWindowFocus);
    document.addEventListener('visibilitychange', this.handleVisibilityChange);
    emitter.on(BUS_EVENTS.WEBSOCKET_RECONNECT, this.onReconnect);
    emitter.on(BUS_EVENTS.WEBSOCKET_DISCONNECT, this.onDisconnect);
  };

  removeEventListeners = () => {
    window.removeEventListener('online', this.handleOnlineEvent);
    window.removeEventListener('focus', this.handleWindowFocus);
    document.removeEventListener(
      'visibilitychange',
      this.handleVisibilityChange
    );
    emitter.off(BUS_EVENTS.WEBSOCKET_RECONNECT, this.onReconnect);
    emitter.off(BUS_EVENTS.WEBSOCKET_DISCONNECT, this.onDisconnect);
  };

  getSecondsSinceDisconnect = () =>
    this.disconnectTime
      ? Math.max(differenceInSeconds(new Date(), this.disconnectTime), 0)
      : 0;

  activeConversationRouteId = () => {
    const {
      conversation_id: conversationId,
      communication_thread_id: threadId,
    } = this.router.currentRoute.value.params;
    return conversationId || threadId;
  };

  getConversationRouteContext = () => {
    const { name, fullPath, params = {} } = this.router.currentRoute.value;
    const communicationThreadMode = [
      'communication_threads_dashboard',
      'communication_thread_conversation',
    ].includes(name);

    const conversationId =
      params.conversation_id || params.communication_thread_id;
    const selectedChat = this.store.getters.getSelectedChat;
    const preserveConversationState =
      selectedChat &&
      String(selectedChat.id) === String(conversationId) &&
      isCommunicationThread(selectedChat) === communicationThreadMode
        ? {
            messages: selectedChat.messages,
            allMessagesLoaded: selectedChat.allMessagesLoaded,
            dataFetched: selectedChat.dataFetched,
            firstUnreadMessageId: selectedChat.meta?.first_unread_message_id,
          }
        : undefined;

    return {
      name,
      fullPath,
      accountId: params.accountId,
      conversationId,
      communicationThreadMode,
      conversationType: communicationThreadMode
        ? 'communication_thread'
        : 'conversation',
      preserveConversationState,
    };
  };

  isConversationRouteContextCurrent = routeContext => {
    const route = this.router.currentRoute.value;
    const params = route.params || {};
    const conversationId =
      params.conversation_id || params.communication_thread_id;

    return (
      route.name === routeContext.name &&
      route.fullPath === routeContext.fullPath &&
      String(params.accountId || '') === String(routeContext.accountId || '') &&
      String(conversationId || '') === String(routeContext.conversationId || '')
    );
  };

  // Force reload if the user is disconnected for more than 3 hours
  handleOnlineEvent = () => {
    if (this.getSecondsSinceDisconnect() >= MAX_DISCONNECT_SECONDS) {
      window.location.reload();
    }
  };

  handleWindowFocus = async () => {
    await this.reconcileVisibleRoute();
  };

  handleVisibilityChange = async () => {
    if (document.hidden) return;

    await this.reconcileVisibleRoute();
  };

  reconcileVisibleRoute = async () => {
    const currentRoute = this.router.currentRoute.value.name;
    if (document.hidden || this.isVisibleReconciliationInFlight) return;
    if (!isAConversationRoute(currentRoute, true)) return;

    this.isVisibleReconciliationInFlight = true;
    try {
      await this.syncActiveConversationMessagesIfNeeded();
    } finally {
      this.isVisibleReconciliationInFlight = false;
    }
  };

  syncActiveConversationMessagesIfNeeded = async () => {
    const currentRoute = this.router.currentRoute.value.name;
    const conversationId = this.activeConversationRouteId();

    if (!conversationId || document.hidden) return;
    if (!isAConversationRoute(currentRoute, true)) return;

    const now = Date.now();
    if (
      now - this.lastActiveConversationSyncAt <
      ACTIVE_CONVERSATION_RESYNC_DEBOUNCE
    ) {
      return;
    }

    this.lastActiveConversationSyncAt = now;

    const routeContext = this.getConversationRouteContext();
    await this.store.dispatch('syncActiveConversationMessages', {
      conversationId: Number(conversationId),
      conversationType: routeContext.conversationType,
      expectedRouteFullPath: routeContext.fullPath,
    });
  };

  fetchConversations = async (
    routeContext = this.getConversationRouteContext()
  ) => {
    if (!this.isConversationRouteContextCurrent(routeContext)) return;

    await this.store.dispatch('updateChatListFilters', {
      page: null,
      updatedWithin: null,
      communicationThreadMode: routeContext.communicationThreadMode,
    });
    if (!this.isConversationRouteContextCurrent(routeContext)) return;

    await this.store.dispatch(
      routeContext.communicationThreadMode
        ? 'fetchCommunicationThreads'
        : 'fetchAllConversations',
      { expectedRouteFullPath: routeContext.fullPath }
    );
  };

  fetchFilteredOrSavedConversations = async (
    queryData,
    routeContext = this.getConversationRouteContext()
  ) => {
    if (!this.isConversationRouteContextCurrent(routeContext)) return;

    const {
      crmPipelineId,
      crmStageId,
      appointmentStatus,
      labelsScope,
      teamScope,
      unread,
      sortBy,
    } = this.store.getters.getChatListFilters || {};
    const routeFilters = Object.fromEntries(
      Object.entries({
        crmPipelineId,
        crmStageId,
        appointmentStatus,
        labelsScope,
        teamScope,
        unread,
        sortBy,
      }).filter(([, value]) => value !== undefined)
    );

    await this.store.dispatch('fetchFilteredConversations', {
      ...routeFilters,
      queryData,
      page: 1,
      communicationThreadMode: routeContext.communicationThreadMode,
      expectedRouteFullPath: routeContext.fullPath,
    });
  };

  fetchConversationsOnReconnect = async (
    routeContext = this.getConversationRouteContext()
  ) => {
    if (!this.isConversationRouteContextCurrent(routeContext)) return;

    const {
      getAppliedConversationFiltersQuery,
      'customViews/getActiveConversationFolder': activeFolder,
    } = this.store.getters;
    const query = getAppliedConversationFiltersQuery?.payload?.length
      ? getAppliedConversationFiltersQuery
      : activeFolder?.query;
    if (query) {
      await this.fetchFilteredOrSavedConversations(query, routeContext);
    } else {
      await this.fetchConversations(routeContext);
    }
  };

  restoreActiveConversationOnReconnect = async routeContext => {
    const { conversationId, communicationThreadMode, fullPath } = routeContext;
    if (
      !conversationId ||
      !this.isConversationRouteContextCurrent(routeContext)
    ) {
      return null;
    }

    const conversations = this.store.getters.getAllConversations || [];
    const activeConversation = conversations.find(
      conversation =>
        String(conversation.id) === String(conversationId) &&
        isCommunicationThread(conversation) === communicationThreadMode
    );
    if (activeConversation) return activeConversation;

    return this.store.dispatch(
      communicationThreadMode ? 'getCommunicationThread' : 'getConversation',
      {
        conversationId,
        expectedRouteFullPath: fullPath,
        preserveConversationState: routeContext.preserveConversationState,
        resumeActiveConversation: true,
      }
    );
  };

  fetchConversationMessagesOnReconnect = async (
    routeContext = this.getConversationRouteContext()
  ) => {
    const { conversationId, conversationType, fullPath } = routeContext;
    if (
      conversationId &&
      this.isConversationRouteContextCurrent(routeContext)
    ) {
      await this.store.dispatch('syncActiveConversationMessages', {
        conversationId: Number(conversationId),
        conversationType,
        expectedRouteFullPath: fullPath,
      });
    }
  };

  fetchNotificationsOnReconnect = async filter => {
    await this.store.dispatch('notifications/index', { ...filter, page: 1 });
  };

  revalidateCaches = async () => {
    const { label, inbox, team } = await this.store.dispatch(
      'accounts/getCacheKeys'
    );
    await Promise.all([
      this.store.dispatch('labels/revalidate', { newKey: label }),
      this.store.dispatch('inboxes/revalidate', { newKey: inbox }),
      this.store.dispatch('teams/revalidate', { newKey: team }),
    ]);
  };

  handleRouteSpecificFetch = async () => {
    const currentRoute = this.router.currentRoute.value.name;
    if (isAConversationRoute(currentRoute, true)) {
      const routeContext = this.getConversationRouteContext();
      await this.fetchConversationsOnReconnect(routeContext);
      if (!this.isConversationRouteContextCurrent(routeContext)) return;
      const activeConversation =
        await this.restoreActiveConversationOnReconnect(routeContext);
      if (
        !activeConversation ||
        !this.isConversationRouteContextCurrent(routeContext)
      ) {
        return;
      }
      const selectedChat = this.store.getters.getSelectedChat;
      const isAlreadyActive =
        selectedChat &&
        String(selectedChat.id) === String(routeContext.conversationId) &&
        isCommunicationThread(selectedChat) ===
          routeContext.communicationThreadMode;
      if (!isAlreadyActive) {
        await this.store.dispatch('setActiveChat', {
          data: activeConversation,
          expectedRouteFullPath: routeContext.fullPath,
          resumeActiveConversation: true,
        });
      }
      await this.fetchConversationMessagesOnReconnect(routeContext);
    } else if (isAInboxViewRoute(currentRoute, true)) {
      await this.fetchNotificationsOnReconnect(
        this.store.getters['notifications/getNotificationFilters']
      );
    } else if (isNotificationRoute(currentRoute)) {
      await this.fetchNotificationsOnReconnect();
    }
  };

  setConversationLastMessageId = async () => {
    const conversationId = this.activeConversationRouteId();
    if (conversationId) {
      const routeContext = this.getConversationRouteContext();
      await this.store.dispatch('setConversationLastMessageId', {
        conversationId: Number(conversationId),
        conversationType: routeContext.conversationType,
      });
    }
  };

  onDisconnect = () => {
    this.disconnectTime = new Date();
    this.setConversationLastMessageId();
  };

  onReconnect = async () => {
    await this.handleRouteSpecificFetch();
    await this.revalidateCaches();
    emitter.emit(BUS_EVENTS.WEBSOCKET_RECONNECT_COMPLETED);
  };
}

export default ReconnectService;
