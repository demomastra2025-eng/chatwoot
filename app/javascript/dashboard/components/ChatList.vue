<script setup>
// [TODO] This componet is too big and bulky to be in the same file, we can consider splitting this into multiple
// composables and components, useVirtualChatList, useChatlistFilters
import {
  ref,
  unref,
  provide,
  computed,
  watch,
  onMounted,
  defineEmits,
} from 'vue';
import { useStore } from 'vuex';
import { useRoute, useRouter } from 'vue-router';
import {
  useMapGetter,
  useFunctionGetter,
} from 'dashboard/composables/store.js';

import { Virtualizer } from 'virtua/vue';
import ChatListHeader from './ChatListHeader.vue';
import Dialog from 'dashboard/components-next/dialog/Dialog.vue';
import ConversationFilter from 'next/filter/ConversationFilter.vue';
import SaveCustomView from 'next/filter/SaveCustomView.vue';
import ChatTypeTabs from './widgets/ChatTypeTabs.vue';
import ConversationItem from './ConversationItem.vue';
import DeleteCustomViews from 'dashboard/routes/dashboard/customviews/DeleteCustomViews.vue';
import ConversationBulkActions from './widgets/conversation/conversationBulkActions/Index.vue';
import TeleportWithDirection from 'dashboard/components-next/TeleportWithDirection.vue';
import Spinner from 'dashboard/components-next/spinner/Spinner.vue';
import IntersectionObserver from 'dashboard/components/IntersectionObserver.vue';
import ConversationResolveAttributesModal from 'dashboard/components-next/ConversationWorkflow/ConversationResolveAttributesModal.vue';

import { useUISettings } from 'dashboard/composables/useUISettings';
import { useAlert } from 'dashboard/composables';
import { useChatListKeyboardEvents } from 'dashboard/composables/chatlist/useChatListKeyboardEvents';
import { useBulkActions } from 'dashboard/composables/chatlist/useBulkActions';
import { useFilter } from 'shared/composables/useFilter';
import { useTrack } from 'dashboard/composables';
import { useI18n } from 'vue-i18n';
import {
  useCamelCase,
  useSnakeCase,
} from 'dashboard/composables/useTransformKeys';
import { useEmitter } from 'dashboard/composables/emitter';
import { useConversationRequiredAttributes } from 'dashboard/composables/useConversationRequiredAttributes';

import { emitter } from 'shared/helpers/mitt';

import wootConstants from 'dashboard/constants/globals';
import advancedFilterOptions from './widgets/conversation/advancedFilterItems';
import filterQueryGenerator from '../helper/filterQueryGenerator.js';
import languages from 'dashboard/components/widgets/conversation/advancedFilterItems/languages';
import countries from 'shared/constants/countries';
import { generateValuesForEditCustomViews } from 'dashboard/helper/customViewsHelper';
import { conversationListPageURL } from '../helper/URLHelper';
import {
  isOnMentionsView,
  isOnParticipatingView,
  isOnUnattendedView,
} from '../store/modules/conversations/helpers/actionHelpers';
import {
  getUserPermissions,
  filterItemsByPermission,
} from 'dashboard/helper/permissionsHelper.js';
import { matchesFilters } from '../store/modules/conversations/helpers/filterHelpers';
import { CONVERSATION_EVENTS } from '../helper/AnalyticsHelper/events';
import { ASSIGNEE_TYPE_TAB_PERMISSIONS } from 'dashboard/constants/permissions.js';
import { conversationMatchesLocalSearch } from './widgets/conversation/helpers/conversationSearch';
import {
  filterConversationsByCommunicationThreadMode,
  getCommunicationThreadChannelInboxes,
} from 'dashboard/helper/communicationThreadHelper';

const props = defineProps({
  conversationInbox: { type: [String, Number], default: 0 },
  teamId: { type: [String, Number], default: 0 },
  label: { type: String, default: '' },
  conversationType: { type: String, default: '' },
  foldersId: { type: [String, Number], default: 0 },
  communicationThreadMode: { type: Boolean, default: false },
  showConversationList: { default: true, type: Boolean },
  isOnExpandedLayout: { default: false, type: Boolean },
});

const emit = defineEmits(['conversationLoad']);
const { uiSettings, updateUISettings } = useUISettings();
const { t } = useI18n();
const router = useRouter();
const route = useRoute();
const store = useStore();

const resolveAttributesModalRef = ref(null);
const conversationListRef = ref(null);
const virtualListRef = ref(null);

provide('contextMenuElementTarget', virtualListRef);

const activeAssigneeTab = ref(wootConstants.ASSIGNEE_TYPE.ME);
const activeStatus = ref(wootConstants.STATUS_TYPE.OPEN);
const activeSortBy = ref(wootConstants.SORT_BY_TYPE.LAST_ACTIVITY_AT_DESC);
const sidebarStatuses = [
  wootConstants.STATUS_TYPE.PENDING,
  wootConstants.STATUS_TYPE.OPEN,
  wootConstants.STATUS_TYPE.SNOOZED,
  wootConstants.STATUS_TYPE.RESOLVED,
];
const showAdvancedFilters = ref(false);
// chatsOnView is to store the chats that are currently visible on the screen,
// which mirrors the conversationList.
const chatsOnView = ref([]);
const foldersQuery = ref({});
const showAddFoldersModal = ref(false);
const showDeleteFoldersModal = ref(false);
const isContextMenuOpen = ref(false);
const appliedFilter = ref([]);
const localSearchQuery = ref('');
const advancedFilterTypes = ref(
  advancedFilterOptions.map(filter => ({
    ...filter,
    attributeName: t(`FILTER.ATTRIBUTES.${filter.attributeI18nKey}`),
  }))
);

const currentUser = useMapGetter('getCurrentUser');
const chatLists = useMapGetter('getFilteredConversations');
const mineChatsList = useMapGetter('getMineChats');
const allChatList = useMapGetter('getAllStatusChats');
const unAssignedChatsList = useMapGetter('getUnAssignedChats');
const participatingChatsList = useMapGetter('getParticipatingChats');
const chatListLoading = useMapGetter('getChatListLoadingStatus');
const activeInbox = useMapGetter('getSelectedInbox');
const conversationStats = useMapGetter('conversationStats/getStats');
const conversationSidebarUnreadCounts = useMapGetter(
  'getConversationSidebarUnreadCounts'
);
const appliedFilters = useMapGetter('getAppliedConversationFiltersV2');
const folders = useMapGetter('customViews/getConversationCustomViews');
const agentList = useMapGetter('agents/getAgents');
const teamsList = useMapGetter('teams/getTeams');
const inboxesList = useMapGetter('inboxes/getInboxes');
const campaigns = useMapGetter('campaigns/getAllCampaigns');
const labels = useMapGetter('labels/getLabels');
const currentAccountId = useMapGetter('getCurrentAccountId');
const getContact = useMapGetter('contacts/getContact');
// We can't useFunctionGetter here since it needs to be called on setup?
const getTeamFn = useMapGetter('teams/getTeam');
const getConversationById = useMapGetter('getConversationById');

useChatListKeyboardEvents(conversationListRef);
const {
  selectedConversations,
  selectedInboxes,
  selectConversation,
  deSelectConversation,
  selectAllConversations,
  resetBulkActions,
  isConversationSelected,
  onAssignAgent,
  onAssignLabels,
  onRemoveLabels,
  onAssignTeamsForBulk,
  onUpdateConversations,
  onMarkConversationsRead,
} = useBulkActions();

const {
  initializeStatusAndAssigneeFilterToModal,
  initializeInboxTeamAndLabelFilterToModal,
} = useFilter({
  filteri18nKey: 'FILTER',
  attributeModel: 'conversation_attribute',
});

const { checkMissingAttributes } = useConversationRequiredAttributes();

// computed

const hasAppliedFilters = computed(() => {
  return appliedFilters.value.length !== 0;
});

const activeFolder = computed(() => {
  if (props.foldersId) {
    const activeView = folders.value.filter(
      view => view.id === Number(props.foldersId)
    );
    const [firstValue] = activeView;
    return firstValue;
  }
  return undefined;
});

const activeFolderName = computed(() => {
  return activeFolder.value?.name;
});

const hasLocalSearch = computed(() => {
  return Boolean(localSearchQuery.value.trim());
});

const hasActiveFolders = computed(() => {
  return Boolean(activeFolder.value && props.foldersId !== 0);
});

const hasAppliedFiltersOrActiveFolders = computed(() => {
  return hasAppliedFilters.value || hasActiveFolders.value;
});

const routeConversationStatus = computed(() => {
  const { status } = route.query;
  return sidebarStatuses.includes(status)
    ? status
    : wootConstants.STATUS_TYPE.OPEN;
});

const currentUserDetails = computed(() => {
  const { id, name } = currentUser.value;
  return { id, name };
});

const userPermissions = computed(() => {
  return getUserPermissions(currentUser.value, currentAccountId.value);
});

const assigneeTabItems = computed(() => {
  return filterItemsByPermission(
    ASSIGNEE_TYPE_TAB_PERMISSIONS,
    userPermissions.value,
    item => item.permissions
  ).map(({ key, count: countKey }) => ({
    key,
    name: t(`CHAT_LIST.ASSIGNEE_TYPE_TABS.${key}`),
    count: conversationStats.value[countKey] || 0,
  }));
});

const showAssigneeInConversationCard = computed(() => {
  return (
    hasAppliedFiltersOrActiveFolders.value ||
    activeAssigneeTab.value === wootConstants.ASSIGNEE_TYPE.ALL
  );
});

const currentPageFilterKey = computed(() => {
  return hasAppliedFiltersOrActiveFolders.value
    ? 'appliedFilters'
    : activeAssigneeTab.value;
});

const inbox = useFunctionGetter('inboxes/getInbox', activeInbox);
const currentPage = useFunctionGetter(
  'conversationPage/getCurrentPageFilter',
  activeAssigneeTab
);
const currentFiltersPage = useFunctionGetter(
  'conversationPage/getCurrentPageFilter',
  currentPageFilterKey
);
const hasCurrentPageEndReached = useFunctionGetter(
  'conversationPage/getHasEndReached',
  currentPageFilterKey
);

const conversationCustomAttributes = useFunctionGetter(
  'attributes/getAttributesByModel',
  'conversation_attribute'
);

const communicationThreadChannelInboxes = ref([]);
const currentCommunicationThreadChannelInboxes = computed(() =>
  getCommunicationThreadChannelInboxes(chatLists.value, activeStatus.value)
);

watch(
  [
    () => props.communicationThreadMode,
    currentCommunicationThreadChannelInboxes,
  ],
  ([isThreadMode, channelInboxes]) => {
    if (!isThreadMode) {
      communicationThreadChannelInboxes.value = [];
      return;
    }

    communicationThreadChannelInboxes.value = channelInboxes;
  },
  { immediate: true }
);

const sortedChannelInboxes = computed(() => {
  const sourceInboxes = props.communicationThreadMode
    ? communicationThreadChannelInboxes.value
    : inboxesList.value;

  return sourceInboxes.slice().sort((a, b) => a.name.localeCompare(b.name));
});

const sidebarUnreadCount = (collection, key) => {
  if (!key) return 0;
  return Number(
    conversationSidebarUnreadCounts.value?.[collection]?.[key] || 0
  );
};

const allConversationUnreadCount = computed(() =>
  Number(conversationSidebarUnreadCounts.value?.all || 0)
);

const channelFilterItems = computed(() => [
  {
    key: 'all',
    label: t('CONVERSATION.COMMUNICATION_THREAD.ALL_CHANNELS'),
    icon: 'i-lucide-mailbox',
    badge: allConversationUnreadCount.value,
  },
  ...sortedChannelInboxes.value.map(channelInbox => ({
    key: `inbox:${channelInbox.id}`,
    label: channelInbox.display_name || channelInbox.name,
    inbox: channelInbox,
    badge: sidebarUnreadCount('inboxes', channelInbox.id),
  })),
]);

const activeChannelFilterKey = computed(() => {
  if (props.conversationInbox) {
    return `inbox:${props.conversationInbox}`;
  }

  return props.communicationThreadMode ? 'all' : '';
});

const shouldShowChannelFilter = computed(() => {
  return props.communicationThreadMode || Boolean(props.conversationInbox);
});

const activeAssigneeTabCount = computed(() => {
  const count = assigneeTabItems.value.find(
    item => item.key === activeAssigneeTab.value
  ).count;
  return count;
});

const conversationListPagination = computed(() => {
  const conversationsPerPage = 25;
  const hasChatsOnView =
    chatsOnView.value &&
    Array.isArray(chatsOnView.value) &&
    !chatsOnView.value.length;
  const isNoFiltersOrFoldersAndChatListNotEmpty =
    !hasAppliedFiltersOrActiveFolders.value && hasChatsOnView;
  const isUnderPerPage =
    chatsOnView.value.length < conversationsPerPage &&
    activeAssigneeTabCount.value < conversationsPerPage &&
    activeAssigneeTabCount.value > chatsOnView.value.length;

  if (isNoFiltersOrFoldersAndChatListNotEmpty && isUnderPerPage) {
    return 1;
  }

  return currentPage.value + 1;
});

const conversationFilters = computed(() => {
  return {
    inboxId: props.conversationInbox ? props.conversationInbox : undefined,
    assigneeType: activeAssigneeTab.value,
    status: activeStatus.value,
    sortBy: activeSortBy.value,
    page: conversationListPagination.value,
    labels: props.label ? [props.label] : undefined,
    teamId: props.teamId || undefined,
    conversationType: props.conversationType || undefined,
  };
});

const activeTeam = computed(() => {
  if (props.teamId) {
    return getTeamFn.value(props.teamId);
  }
  return {};
});

const pageTitle = computed(() => {
  if (hasAppliedFilters.value) {
    return t('CHAT_LIST.TAB_HEADING');
  }
  if (inbox.value.name) {
    return inbox.value.name;
  }
  if (activeTeam.value.name) {
    return activeTeam.value.name;
  }
  if (props.label) {
    return `#${props.label}`;
  }
  if (props.conversationType === wootConstants.CONVERSATION_TYPE.MENTION) {
    return t('CHAT_LIST.MENTION_HEADING');
  }
  if (
    props.conversationType === wootConstants.CONVERSATION_TYPE.PARTICIPATING
  ) {
    return t('CONVERSATION_PARTICIPANTS.SIDEBAR_MENU_TITLE');
  }
  if (props.conversationType === wootConstants.CONVERSATION_TYPE.UNATTENDED) {
    return t('CHAT_LIST.UNATTENDED_HEADING');
  }
  if (hasActiveFolders.value) {
    return activeFolder.value.name;
  }
  if (props.communicationThreadMode) {
    return t('CONVERSATION.COMMUNICATION_THREAD.ALL_CHANNELS');
  }
  return t('CHAT_LIST.TAB_HEADING');
});

function filterByAssigneeTab(conversations) {
  if (activeAssigneeTab.value === wootConstants.ASSIGNEE_TYPE.ME) {
    return conversations.filter(
      c => c.meta?.assignee?.id === currentUser.value?.id
    );
  }
  if (activeAssigneeTab.value === wootConstants.ASSIGNEE_TYPE.UNASSIGNED) {
    return conversations.filter(c => !c.meta?.assignee);
  }
  return [...conversations];
}

const conversationList = computed(() => {
  let localConversationList = [];

  if (!hasAppliedFiltersOrActiveFolders.value) {
    const filters = conversationFilters.value;
    if (
      props.conversationType === wootConstants.CONVERSATION_TYPE.PARTICIPATING
    ) {
      localConversationList = filterByAssigneeTab(
        participatingChatsList.value(filters)
      );
    } else if (activeAssigneeTab.value === 'me') {
      localConversationList = [...mineChatsList.value(filters)];
    } else if (activeAssigneeTab.value === 'unassigned') {
      localConversationList = [...unAssignedChatsList.value(filters)];
    } else {
      localConversationList = [...allChatList.value(filters)];
    }
  } else {
    localConversationList = [...chatLists.value];
  }

  if (activeFolder.value) {
    const { payload } = activeFolder.value.query;
    localConversationList = localConversationList.filter(conversation => {
      return matchesFilters(conversation, payload);
    });
  }

  return filterConversationsByCommunicationThreadMode(
    localConversationList,
    props.communicationThreadMode
  );
});

const displayedConversationList = computed(() => {
  if (!hasLocalSearch.value) {
    return conversationList.value;
  }

  return conversationList.value.filter(conversation => {
    const senderId = conversation?.meta?.sender?.id;
    const contact = senderId ? getContact.value(senderId) : {};

    return conversationMatchesLocalSearch(
      conversation,
      contact,
      localSearchQuery.value
    );
  });
});

const showEndOfListMessage = computed(() => {
  return (
    displayedConversationList.value.length &&
    hasCurrentPageEndReached.value &&
    !chatListLoading.value
  );
});

const allConversationsSelected = computed(() => {
  if (!displayedConversationList.value.length) {
    return false;
  }

  return (
    displayedConversationList.value.length ===
      selectedConversations.value.length &&
    displayedConversationList.value.every(el =>
      selectedConversations.value.includes(el.id)
    )
  );
});

const uniqueInboxes = computed(() => {
  return [...new Set(selectedInboxes.value)];
});

// ---------------------- Methods -----------------------
function setFiltersFromUISettings() {
  const { conversations_filter_by: filterBy = {} } = uiSettings.value;
  const { order_by: orderBy } = filterBy;
  activeStatus.value = routeConversationStatus.value;
  activeSortBy.value = Object.values(wootConstants.SORT_BY_TYPE).includes(
    orderBy
  )
    ? orderBy
    : wootConstants.SORT_BY_TYPE.LAST_ACTIVITY_AT_DESC;
}

function updateConversationStatusQuery(status) {
  const nextStatus = sidebarStatuses.includes(status)
    ? status
    : wootConstants.STATUS_TYPE.OPEN;

  if (route.query.status === nextStatus) {
    return;
  }

  router.push({
    name: route.name,
    params: route.params,
    query: {
      ...route.query,
      status: nextStatus,
    },
  });
}

function emitConversationLoaded() {
  emit('conversationLoad');
}

function clearLocalSearch() {
  localSearchQuery.value = '';
  emitter.emit('clearSearchInput');
}

function fetchFilteredConversations(payload) {
  payload = useSnakeCase(payload);
  let page = currentFiltersPage.value + 1;
  store
    .dispatch('fetchFilteredConversations', {
      queryData: filterQueryGenerator(payload),
      page,
    })
    .then(emitConversationLoaded);

  showAdvancedFilters.value = false;
}

function fetchSavedFilteredConversations(payload) {
  payload = useSnakeCase(payload);
  let page = currentFiltersPage.value + 1;
  store
    .dispatch('fetchFilteredConversations', {
      queryData: payload,
      page,
    })
    .then(emitConversationLoaded);
}

function onApplyFilter(payload) {
  payload = useSnakeCase(payload);
  resetBulkActions();
  foldersQuery.value = filterQueryGenerator(payload);
  store.dispatch('conversationPage/reset');
  store.dispatch('emptyAllConversations');
  fetchFilteredConversations(payload);
}

function closeAdvanceFiltersModal() {
  showAdvancedFilters.value = false;
  appliedFilter.value = [];
}

function onUpdateSavedFilter(payload, folderName) {
  const transformedPayload = useSnakeCase(payload);
  const payloadData = {
    ...unref(activeFolder),
    name: unref(folderName),
    query: filterQueryGenerator(transformedPayload),
  };
  store.dispatch('customViews/update', payloadData);
  closeAdvanceFiltersModal();
}

function onClickOpenAddFoldersModal() {
  showAddFoldersModal.value = true;
}

function onCloseAddFoldersModal() {
  showAddFoldersModal.value = false;
}

function onClickOpenDeleteFoldersModal() {
  showDeleteFoldersModal.value = true;
}

function onCloseDeleteFoldersModal() {
  showDeleteFoldersModal.value = false;
}

function setParamsForEditFolderModal() {
  // Here we are setting the params for edit folder modal to show the existing values.

  // For agent, team, inboxes,and campaigns we get only the id's from the query.
  // So we are mapping the id's to the actual values.

  // For labels we get the name of the label from the query.
  // If we delete the label from the label list then we will not be able to show the label name.

  // For custom attributes we get only attribute key.
  // So we are mapping it to find the input type of the attribute to show in the edit folder modal.
  return {
    agents: agentList.value,
    teams: teamsList.value,
    inboxes: inboxesList.value,
    labels: labels.value,
    campaigns: campaigns.value,
    languages: languages,
    countries: countries,
    priority: [
      { id: 'low', name: t('CONVERSATION.PRIORITY.OPTIONS.LOW') },
      { id: 'medium', name: t('CONVERSATION.PRIORITY.OPTIONS.MEDIUM') },
      { id: 'high', name: t('CONVERSATION.PRIORITY.OPTIONS.HIGH') },
      { id: 'urgent', name: t('CONVERSATION.PRIORITY.OPTIONS.URGENT') },
    ],
    filterTypes: advancedFilterTypes.value,
    allCustomAttributes: conversationCustomAttributes.value,
  };
}

function initializeExistingFilterToModal() {
  const statusFilter = initializeStatusAndAssigneeFilterToModal(
    activeStatus.value,
    currentUserDetails.value,
    activeAssigneeTab.value
  );
  // TODO: Remove the usage of useCamelCase after migrating useFilter to camelcase
  if (statusFilter) {
    appliedFilter.value = [...appliedFilter.value, useCamelCase(statusFilter)];
  }

  // TODO: Remove the usage of useCamelCase after migrating useFilter to camelcase
  const otherFilters = initializeInboxTeamAndLabelFilterToModal(
    props.conversationInbox,
    inbox.value,
    props.teamId,
    activeTeam.value,
    props.label
  ).map(useCamelCase);

  appliedFilter.value = [...appliedFilter.value, ...otherFilters];
}

function initializeFolderToFilterModal(newActiveFolder) {
  // Here we are setting the params for edit folder modal.
  //  To show the existing values. when we click on edit folder button.

  // Here we get the query from the active folder.
  // And we are mapping the query to the actual values.
  // To show in the edit folder modal by the help of generateValuesForEditCustomViews helper.
  const query = unref(newActiveFolder)?.query?.payload;
  if (!Array.isArray(query)) return;

  const newFilters = query.map(filter => {
    const transformed = useCamelCase(filter);
    const values = Array.isArray(transformed.values)
      ? generateValuesForEditCustomViews(
          useSnakeCase(filter),
          setParamsForEditFolderModal()
        )
      : [];

    return {
      attributeKey: transformed.attributeKey,
      attributeModel: transformed.attributeModel,
      customAttributeType: transformed.customAttributeType,
      filterOperator: transformed.filterOperator,
      queryOperator: transformed.queryOperator ?? 'and',
      values,
    };
  });

  appliedFilter.value = [...appliedFilter.value, ...newFilters];
}

function initalizeAppliedFiltersToModal() {
  appliedFilter.value = [...appliedFilters.value];
}

function onToggleAdvanceFiltersModal() {
  if (showAdvancedFilters.value === true) {
    closeAdvanceFiltersModal();
    return;
  }

  if (!hasAppliedFilters.value && !hasActiveFolders.value) {
    initializeExistingFilterToModal();
  }
  if (hasActiveFolders.value) {
    initializeFolderToFilterModal(activeFolder.value);
  }
  if (hasAppliedFilters.value) {
    initalizeAppliedFiltersToModal();
  }

  showAdvancedFilters.value = true;
}

function fetchConversations() {
  store.dispatch('updateChatListFilters', conversationFilters.value);
  store
    .dispatch(
      props.communicationThreadMode
        ? 'fetchCommunicationThreads'
        : 'fetchAllConversations'
    )
    .then(emitConversationLoaded);
}

function resetAndFetchData() {
  appliedFilter.value = [];
  resetBulkActions();
  store.dispatch('conversationPage/reset');
  store.dispatch('emptyAllConversations');
  store.dispatch('clearConversationFilters');
  if (hasActiveFolders.value) {
    const payload = activeFolder.value.query;
    fetchSavedFilteredConversations(payload);
  }
  if (props.foldersId) {
    return;
  }
  fetchConversations();
}

function loadMoreConversations() {
  if (hasCurrentPageEndReached.value || chatListLoading.value) {
    return;
  }

  if (!hasAppliedFiltersOrActiveFolders.value) {
    fetchConversations();
  } else if (hasActiveFolders.value) {
    const payload = activeFolder.value.query;
    fetchSavedFilteredConversations(payload);
  } else if (hasAppliedFilters.value) {
    fetchFilteredConversations(appliedFilters.value);
  }
}

// Use IntersectionObserver instead of @scroll since Virtualizer only emits on user scroll.
// If the list doesn’t fill the viewport, loading can stall.
// IntersectionObserver triggers as soon as the sentinel is visible.
const intersectionObserverOptions = computed(() => ({
  root: conversationListRef.value,
  rootMargin: '100px 0px 100px 0px',
}));

function updateAssigneeTab(selectedTab) {
  if (activeAssigneeTab.value !== selectedTab) {
    resetBulkActions();
    clearLocalSearch();
    activeAssigneeTab.value = selectedTab;
    if (!currentPage.value) {
      fetchConversations();
    }
  }
}

function onBasicFilterChange(value, type) {
  if (type === 'status') {
    updateConversationStatusQuery(value);
    return;
  }

  activeSortBy.value = value;
  resetAndFetchData();
}

function channelFilterQuery() {
  const query = { ...route.query };
  delete query.messageId;

  return {
    ...query,
    status: activeStatus.value,
  };
}

function onChannelFilterSelect(item) {
  resetBulkActions();
  clearLocalSearch();

  const accountId = currentAccountId.value || route.params.accountId;
  if (item.key === 'all') {
    router.push({
      name: 'communication_threads_dashboard',
      params: { accountId },
      query: channelFilterQuery(),
    });
    return;
  }

  if (!item.inbox?.id) return;

  router.push({
    name: 'inbox_dashboard',
    params: { accountId, inbox_id: item.inbox.id },
    query: channelFilterQuery(),
  });
}

function openLastSavedItemInFolder() {
  const lastItemOfFolder = folders.value[folders.value.length - 1];
  const lastItemId = lastItemOfFolder.id;
  router.push({
    name: 'folder_conversations',
    params: { id: lastItemId },
  });
}

function openLastItemAfterDeleteInFolder() {
  if (folders.value.length > 0) {
    openLastSavedItemInFolder();
  } else {
    router.push({ name: 'home' });
    fetchConversations();
  }
}

function redirectToConversationList() {
  const {
    params: { accountId, inbox_id: inboxId, label, teamId },
    name,
  } = route;

  let conversationType = '';
  if (isOnMentionsView({ route: { name } })) {
    conversationType = wootConstants.CONVERSATION_TYPE.MENTION;
  } else if (isOnParticipatingView({ route: { name } })) {
    conversationType = wootConstants.CONVERSATION_TYPE.PARTICIPATING;
  } else if (isOnUnattendedView({ route: { name } })) {
    conversationType = wootConstants.CONVERSATION_TYPE.UNATTENDED;
  }
  router.push(
    conversationListPageURL({
      accountId,
      conversationType: conversationType,
      customViewId: props.foldersId,
      inboxId,
      label,
      teamId,
      status: activeStatus.value,
      communicationThread: props.communicationThreadMode,
    })
  );
}

function normalizeContextConversationId(conversationId) {
  return Array.isArray(conversationId) ? conversationId[0] : conversationId;
}

function currentLabelsForContextConversation(conversationId) {
  return getConversationById.value(conversationId)?.labels || [];
}

async function updateCommunicationThreadLabels(conversationId, labelList) {
  await store.dispatch('updateCommunicationThreadLabels', {
    conversationId,
    labels: labelList,
  });
}

async function handleAssignAgent(agent, conversationId = null) {
  const targetConversationId = normalizeContextConversationId(conversationId);
  if (props.communicationThreadMode && targetConversationId) {
    try {
      await store.dispatch('assignAgent', {
        conversationId: targetConversationId,
        agentId: agent.id,
      });
      useAlert(
        t('CONVERSATION.CARD_CONTEXT_MENU.API.AGENT_ASSIGNMENT.SUCCESFUL', {
          agentName: agent.name,
          conversationId: targetConversationId,
        })
      );
    } catch (error) {
      useAlert(t('CONVERSATION.CARD_CONTEXT_MENU.API.AGENT_ASSIGNMENT.FAILED'));
    }
    return;
  }

  await onAssignAgent(agent, conversationId, props.communicationThreadMode);
}

async function handleAssignTeam(team, conversationId = null) {
  const targetConversationId = normalizeContextConversationId(conversationId);
  if (targetConversationId) {
    try {
      await store.dispatch('assignTeam', {
        conversationId: targetConversationId,
        teamId: team.id,
      });
      useAlert(
        t('CONVERSATION.CARD_CONTEXT_MENU.API.TEAM_ASSIGNMENT.SUCCESFUL', {
          team: team.name,
          conversationId: targetConversationId,
        })
      );
    } catch (error) {
      useAlert(t('CONVERSATION.CARD_CONTEXT_MENU.API.TEAM_ASSIGNMENT.FAILED'));
    }
    return;
  }

  await onAssignTeamsForBulk(team, props.communicationThreadMode);
}

async function handleAssignLabels(newLabels, conversationId = null) {
  const targetConversationId = normalizeContextConversationId(conversationId);
  if (props.communicationThreadMode && targetConversationId) {
    try {
      const nextLabels = Array.from(
        new Set([
          ...currentLabelsForContextConversation(targetConversationId),
          ...newLabels,
        ])
      );
      await updateCommunicationThreadLabels(targetConversationId, nextLabels);
      useAlert(
        t('CONVERSATION.CARD_CONTEXT_MENU.API.LABEL_ASSIGNMENT.SUCCESFUL', {
          labelName: newLabels[0],
          conversationId: targetConversationId,
        })
      );
    } catch (error) {
      useAlert(t('CONVERSATION.CARD_CONTEXT_MENU.API.LABEL_ASSIGNMENT.FAILED'));
    }
    return;
  }

  await onAssignLabels(
    newLabels,
    conversationId,
    props.communicationThreadMode
  );
}

async function handleRemoveLabels(labelsToRemove, conversationId = null) {
  const targetConversationId = normalizeContextConversationId(conversationId);
  if (props.communicationThreadMode && targetConversationId) {
    try {
      const labelsToRemoveSet = new Set(labelsToRemove);
      const nextLabels = currentLabelsForContextConversation(
        targetConversationId
      ).filter(label => !labelsToRemoveSet.has(label));
      await updateCommunicationThreadLabels(targetConversationId, nextLabels);
      useAlert(
        t('CONVERSATION.CARD_CONTEXT_MENU.API.LABEL_REMOVAL.SUCCESFUL', {
          labelName: labelsToRemove[0],
          conversationId: targetConversationId,
        })
      );
    } catch (error) {
      useAlert(t('CONVERSATION.CARD_CONTEXT_MENU.API.LABEL_REMOVAL.FAILED'));
    }
    return;
  }

  await onRemoveLabels(labelsToRemove, conversationId);
}

async function assignPriority(priority, conversationId = null) {
  store.dispatch('setCurrentChatPriority', {
    priority,
    conversationId,
  });
  store.dispatch('assignPriority', { conversationId, priority }).then(() => {
    useTrack(CONVERSATION_EVENTS.CHANGE_PRIORITY, {
      newValue: priority,
      from: 'Context menu',
    });
    useAlert(
      t('CONVERSATION.PRIORITY.CHANGE_PRIORITY.SUCCESSFUL', {
        priority,
        conversationId,
      })
    );
  });
}

async function markAsUnread(conversationId) {
  try {
    await store.dispatch('markMessagesUnread', {
      id: conversationId,
    });
    redirectToConversationList();
  } catch (error) {
    // Ignore error
  }
}
async function markAsRead(conversationId) {
  try {
    await store.dispatch('markMessagesRead', {
      id: conversationId,
    });
  } catch (error) {
    // Ignore error
  }
}

function toggleConversationStatus(
  conversationId,
  status,
  snoozedUntil,
  customAttributes = null
) {
  const payload = {
    conversationId,
    status,
    snoozedUntil,
  };

  if (customAttributes) {
    payload.customAttributes = customAttributes;
  }

  store.dispatch('toggleStatus', payload).then(() => {
    useAlert(t('CONVERSATION.CHANGE_STATUS'));
  });
}

function handleResolveConversation(conversationId, status, snoozedUntil) {
  if (status !== wootConstants.STATUS_TYPE.RESOLVED) {
    toggleConversationStatus(conversationId, status, snoozedUntil);
    return;
  }

  // Check for required attributes before resolving
  const conversation = getConversationById.value(conversationId);
  const currentCustomAttributes = conversation?.custom_attributes || {};
  const { hasMissing, missing } = checkMissingAttributes(
    currentCustomAttributes
  );

  if (hasMissing) {
    // Pass conversation context through the modal's API
    const conversationContext = {
      id: conversationId,
      snoozedUntil,
    };
    resolveAttributesModalRef.value?.open(
      missing,
      currentCustomAttributes,
      conversationContext
    );
  } else {
    toggleConversationStatus(conversationId, status, snoozedUntil);
  }
}

function handleResolveWithAttributes({ attributes, context }) {
  if (context) {
    const existingConversation = getConversationById.value(context.id);
    const currentCustomAttributes =
      existingConversation?.custom_attributes || {};
    const mergedAttributes = { ...currentCustomAttributes, ...attributes };

    toggleConversationStatus(
      context.id,
      wootConstants.STATUS_TYPE.RESOLVED,
      context.snoozedUntil,
      mergedAttributes
    );
  }
}

function allSelectedConversationsStatus(status) {
  if (!selectedConversations.value.length) return false;
  return selectedConversations.value.every(item => {
    return getConversationById.value(item)?.status === status;
  });
}

function onContextMenuToggle(state) {
  isContextMenuOpen.value = state;
}

function toggleSelectAll(check) {
  selectAllConversations(check, displayedConversationList);
}

useEmitter('fetch_conversation_stats', () => {
  if (hasAppliedFiltersOrActiveFolders.value) return;
  store.dispatch('conversationStats/get', conversationFilters.value);
});

onMounted(() => {
  store.dispatch('setChatListFilters', conversationFilters.value);
  setFiltersFromUISettings();
  store.dispatch('setChatStatusFilter', activeStatus.value);
  store.dispatch('setChatSortFilter', activeSortBy.value);
  resetAndFetchData();
  if (hasActiveFolders.value) {
    store.dispatch('campaigns/get');
  }
});

const deleteConversationDialogRef = ref(null);
const selectedConversationId = ref(null);

async function deleteConversation() {
  try {
    await store.dispatch('deleteConversation', selectedConversationId.value);
    redirectToConversationList();
    selectedConversationId.value = null;
    deleteConversationDialogRef.value.close();
    useAlert(t('CONVERSATION.SUCCESS_DELETE_CONVERSATION'));
  } catch (error) {
    useAlert(t('CONVERSATION.FAIL_DELETE_CONVERSATION'));
  }
}

const handleDelete = conversationId => {
  selectedConversationId.value = conversationId;
  deleteConversationDialogRef.value.open();
};

provide('selectConversation', selectConversation);
provide('deSelectConversation', deSelectConversation);
provide('assignAgent', handleAssignAgent);
provide('assignTeam', handleAssignTeam);
provide('assignLabels', handleAssignLabels);
provide('removeLabels', handleRemoveLabels);
provide('updateConversationStatus', handleResolveConversation);
provide('toggleContextMenu', onContextMenuToggle);
provide('markAsUnread', markAsUnread);
provide('markAsRead', markAsRead);
provide('assignPriority', assignPriority);
provide('isConversationSelected', isConversationSelected);
provide('deleteConversation', handleDelete);

watch(activeTeam, () => {
  clearLocalSearch();
  resetAndFetchData();
});

watch(routeConversationStatus, (newStatus, oldStatus) => {
  if (newStatus === oldStatus) {
    return;
  }

  activeStatus.value = newStatus;
  store.dispatch('setChatStatusFilter', newStatus);
  updateUISettings({
    conversations_filter_by: {
      ...(uiSettings.value?.conversations_filter_by || {}),
      status: newStatus,
      order_by: activeSortBy.value,
    },
  });
  clearLocalSearch();
  resetAndFetchData();
});

watch(
  computed(() => props.conversationInbox),
  () => {
    clearLocalSearch();
    resetAndFetchData();
  }
);
watch(
  computed(() => props.label),
  () => {
    clearLocalSearch();
    resetAndFetchData();
  }
);
watch(
  computed(() => props.conversationType),
  () => {
    clearLocalSearch();
    resetAndFetchData();
  }
);
watch(
  computed(() => props.communicationThreadMode),
  () => {
    clearLocalSearch();
    resetAndFetchData();
  }
);

watch(activeFolder, (newVal, oldVal) => {
  if (newVal !== oldVal) {
    store.dispatch('customViews/setActiveConversationFolder', newVal || null);
  }
  clearLocalSearch();
  resetAndFetchData();
});

watch(chatLists, () => {
  chatsOnView.value = conversationList.value;
});

watch(conversationFilters, (newVal, oldVal) => {
  if (newVal !== oldVal) {
    store.dispatch('updateChatListFilters', newVal);
  }
});
</script>

<template>
  <div
    class="flex flex-col flex-shrink-0 conversations-list-wrap bg-n-surface-1"
    :class="[
      { hidden: !showConversationList },
      isOnExpandedLayout ? 'basis-full' : 'w-[340px] 2xl:w-[412px]',
    ]"
  >
    <slot />
    <ChatListHeader
      v-model:local-search-query="localSearchQuery"
      :page-title="pageTitle"
      :has-applied-filters="hasAppliedFilters"
      :has-active-folders="hasActiveFolders"
      :is-on-expanded-layout="isOnExpandedLayout"
      :conversation-stats="conversationStats"
      :is-list-loading="chatListLoading && !conversationList.length"
      :show-channel-filter="shouldShowChannelFilter"
      :channel-filter-items="channelFilterItems"
      :active-channel-filter-key="activeChannelFilterKey"
      @add-folders="onClickOpenAddFoldersModal"
      @delete-folders="onClickOpenDeleteFoldersModal"
      @filters-modal="onToggleAdvanceFiltersModal"
      @reset-filters="resetAndFetchData"
      @basic-filter-change="onBasicFilterChange"
      @channel-filter-select="onChannelFilterSelect"
    />

    <TeleportWithDirection
      v-if="showAddFoldersModal"
      to="#saveFilterTeleportTarget"
    >
      <SaveCustomView
        v-model="appliedFilter"
        :custom-views-query="foldersQuery"
        :open-last-saved-item="openLastSavedItemInFolder"
        @close="onCloseAddFoldersModal"
      />
    </TeleportWithDirection>

    <DeleteCustomViews
      v-if="showDeleteFoldersModal"
      v-model:show="showDeleteFoldersModal"
      :active-custom-view="activeFolder"
      :custom-views-id="foldersId"
      :open-last-item-after-delete="openLastItemAfterDeleteInFolder"
      @close="onCloseDeleteFoldersModal"
    />

    <ChatTypeTabs
      v-if="!hasAppliedFiltersOrActiveFolders"
      :items="assigneeTabItems"
      :active-tab="activeAssigneeTab"
      is-compact
      @chat-tab-change="updateAssigneeTab"
    />

    <p
      v-if="!chatListLoading && !conversationList.length && !hasLocalSearch"
      class="flex overflow-auto justify-center items-center p-4"
    >
      {{ $t('CHAT_LIST.LIST.404') }}
    </p>
    <ConversationBulkActions
      v-if="selectedConversations.length"
      :conversations="selectedConversations"
      :all-conversations-selected="allConversationsSelected"
      :selectable-conversations-count="displayedConversationList.length"
      :selected-inboxes="uniqueInboxes"
      :show-open-action="allSelectedConversationsStatus('open')"
      :show-resolved-action="allSelectedConversationsStatus('resolved')"
      :show-snoozed-action="allSelectedConversationsStatus('snoozed')"
      @select-all-conversations="toggleSelectAll"
      @assign-agent="handleAssignAgent"
      @update-conversations="
        (status, snoozedUntil) =>
          onUpdateConversations(status, snoozedUntil, communicationThreadMode)
      "
      @assign-labels="handleAssignLabels"
      @assign-team="handleAssignTeam"
      @mark-read="() => onMarkConversationsRead(communicationThreadMode)"
    />
    <div
      ref="conversationListRef"
      class="flex-1 min-h-0 overflow-y-auto conversations-list"
      :class="{ '!overflow-hidden': isContextMenuOpen }"
    >
      <Virtualizer
        v-if="displayedConversationList.length"
        ref="virtualListRef"
        v-slot="{ item, index }"
        :data="displayedConversationList"
      >
        <ConversationItem
          :source="item"
          :label="label"
          :team-id="teamId"
          :folders-id="foldersId"
          :conversation-type="conversationType"
          :active-status="activeStatus"
          :communication-thread-mode="communicationThreadMode"
          :show-assignee="showAssigneeInConversationCard"
          :data-index="index"
          @select-conversation="selectConversation"
          @de-select-conversation="deSelectConversation"
        />
      </Virtualizer>
      <p
        v-else-if="!chatListLoading && hasLocalSearch"
        class="flex overflow-auto justify-center items-center p-4 text-center text-n-slate-11"
      >
        {{ $t('CHAT_LIST.LOCAL_SEARCH.EMPTY') }}
      </p>
      <div v-if="chatListLoading" class="flex justify-center my-4">
        <Spinner class="text-n-brand" />
      </div>
      <p
        v-else-if="showEndOfListMessage"
        class="p-4 text-center text-n-slate-11"
      >
        {{ $t('CHAT_LIST.EOF') }}
      </p>
      <IntersectionObserver
        v-else
        :options="intersectionObserverOptions"
        @observed="loadMoreConversations"
      />
    </div>
    <Dialog
      ref="deleteConversationDialogRef"
      type="alert"
      :title="
        $t('CONVERSATION.DELETE_CONVERSATION.TITLE', {
          conversationId: selectedConversationId,
        })
      "
      :description="$t('CONVERSATION.DELETE_CONVERSATION.DESCRIPTION')"
      :confirm-button-label="$t('CONVERSATION.DELETE_CONVERSATION.CONFIRM')"
      @confirm="deleteConversation"
      @close="selectedConversationId = null"
    />
    <TeleportWithDirection
      v-if="showAdvancedFilters"
      to="#conversationFilterTeleportTarget"
    >
      <ConversationFilter
        v-model="appliedFilter"
        :folder-name="activeFolderName"
        :is-folder-view="hasActiveFolders"
        @apply-filter="onApplyFilter"
        @update-folder="onUpdateSavedFilter"
        @close="closeAdvanceFiltersModal"
      />
    </TeleportWithDirection>
    <ConversationResolveAttributesModal
      ref="resolveAttributesModalRef"
      @submit="handleResolveWithAttributes"
    />
  </div>
</template>
