<script setup>
// [TODO] This componet is too big and bulky to be in the same file, we can consider splitting this into multiple
// composables and components, useVirtualChatList, useChatlistFilters
import {
  ref,
  unref,
  provide,
  computed,
  watch,
  nextTick,
  onMounted,
  defineEmits,
  defineAsyncComponent,
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
import ConversationItem from './ConversationItem.vue';
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
import { FEATURE_FLAGS } from 'dashboard/featureFlags';
import advancedFilterOptions from './widgets/conversation/advancedFilterItems';
import filterQueryGenerator, {
  normalizeFilterQueryOperator,
} from '../helper/filterQueryGenerator.js';
import languages from 'dashboard/components/widgets/conversation/advancedFilterItems/languages';
import countries from 'shared/constants/countries';
import { generateValuesForEditCustomViews } from 'dashboard/helper/customViewsHelper';
import { conversationListPageURL } from '../helper/URLHelper';
import {
  extractSingleStatusFilter,
  mergeRouteStatusFilter,
} from '../helper/conversationStatusFilter';
import {
  isOnMentionsView,
  isOnParticipatingView,
  isOnUnattendedView,
} from '../store/modules/conversations/helpers/actionHelpers';
import { filterByUnread } from '../store/modules/conversations/helpers';
import { matchesFilters } from '../store/modules/conversations/helpers/filterHelpers';
import { CONVERSATION_EVENTS } from '../helper/AnalyticsHelper/events';
import { resolveBulkSelectionPayload } from '../helper/bulkSelection';
import { conversationMatchesLocalSearch } from './widgets/conversation/helpers/conversationSearch';
import { filterConversationsByCommunicationThreadMode } from 'dashboard/helper/communicationThreadHelper';
import { labelDisplayTitle } from 'dashboard/helper/labels';
import { useCrmReferencesStore } from 'dashboard/stores/crm/references';
import { resolveDefaultPipelineWithStages } from 'dashboard/components-next/sidebar/crmDefaultPipelineSidebar';
import {
  isValidConversationPipelineSelection,
  resolveVisibleConversationPipelines,
} from 'dashboard/components-next/sidebar/conversationPipelineVisibility';
import { isConversationAssigneeSelectionLocked } from 'dashboard/components-next/sidebar/sidebarVisibility';
import {
  CONVERSATION_LIST_CONTEXT_SETTINGS_KEY,
  conversationListContextKey,
  conversationListContextState,
  updatedConversationListContextSettings,
} from 'dashboard/helper/conversationListContext';
import {
  APPOINTMENT_STATUS_ANY,
  APPOINTMENT_STATUS_VALUES,
} from 'dashboard/routes/dashboard/scheduling/constants';

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

const ConversationFilter = defineAsyncComponent(
  () => import('next/filter/ConversationFilter.vue')
);
const SaveCustomView = defineAsyncComponent(
  () => import('next/filter/SaveCustomView.vue')
);
const DeleteCustomViews = defineAsyncComponent(
  () => import('dashboard/routes/dashboard/customviews/DeleteCustomViews.vue')
);
const ConversationBulkActions = defineAsyncComponent(
  () => import('./widgets/conversation/conversationBulkActions/Index.vue')
);
const loadCommunicationThreadDeleteDialog = () =>
  import('./widgets/conversation/CommunicationThreadDeleteDialog.vue');
const CommunicationThreadDeleteDialog = defineAsyncComponent(
  loadCommunicationThreadDeleteDialog
);

const { uiSettings, updateUISettings } = useUISettings();
const { t } = useI18n();
const router = useRouter();
const route = useRoute();
const store = useStore();
const crmReferencesStore = useCrmReferencesStore();

const resolveAttributesModalRef = ref(null);
const conversationListRef = ref(null);
const virtualListRef = ref(null);

provide('contextMenuElementTarget', virtualListRef);

const activeAssigneeTab = ref(wootConstants.ASSIGNEE_TYPE.ALL);
const activeStatus = ref(wootConstants.STATUS_TYPE.OPEN);
const activeSortBy = ref(wootConstants.SORT_BY_TYPE.LAST_ACTIVITY_AT_DESC);
const sidebarStatuses = [
  wootConstants.STATUS_TYPE.ALL,
  wootConstants.STATUS_TYPE.PENDING,
  wootConstants.STATUS_TYPE.OPEN,
  wootConstants.STATUS_TYPE.SNOOZED,
  wootConstants.STATUS_TYPE.RESOLVED,
];
const showAdvancedFilters = ref(false);
const pendingStatusRouteSyncs = new Map();
let statusRouteSyncGeneration = 0;
let filterApplicationGeneration = 0;
let latestStatusRouteIntent = wootConstants.STATUS_TYPE.OPEN;
// chatsOnView is to store the chats that are currently visible on the screen,
// which mirrors the conversationList.
const chatsOnView = ref([]);
const foldersQuery = ref({});
const showAddFoldersModal = ref(false);
const showDeleteFoldersModal = ref(false);
const isContextMenuOpen = ref(false);
const appliedFilter = ref([]);
const localSearchQuery = ref('');

const filterAttributeName = attributeI18nKey => {
  switch (attributeI18nKey) {
    case 'ASSIGNEE_NAME':
      return t('FILTER.ATTRIBUTES.ASSIGNEE_NAME');
    case 'BROWSER_LANGUAGE':
      return t('FILTER.ATTRIBUTES.BROWSER_LANGUAGE');
    case 'CAMPAIGN_NAME':
      return t('FILTER.ATTRIBUTES.CAMPAIGN_NAME');
    case 'CONVERSATION_IDENTIFIER':
      return t('FILTER.ATTRIBUTES.CONVERSATION_IDENTIFIER');
    case 'CREATED_AT':
      return t('FILTER.ATTRIBUTES.CREATED_AT');
    case 'CRM_STAGE':
      return t('FILTER.ATTRIBUTES.CRM_STAGE');
    case 'INBOX_NAME':
      return t('FILTER.ATTRIBUTES.INBOX_NAME');
    case 'LABELS':
      return t('FILTER.ATTRIBUTES.LABELS');
    case 'LAST_ACTIVITY':
      return t('FILTER.ATTRIBUTES.LAST_ACTIVITY');
    case 'PRIORITY':
      return t('FILTER.ATTRIBUTES.PRIORITY');
    case 'REFERER_LINK':
      return t('FILTER.ATTRIBUTES.REFERER_LINK');
    case 'STATUS':
      return t('FILTER.ATTRIBUTES.STATUS');
    case 'TEAM_NAME':
      return t('FILTER.ATTRIBUTES.TEAM_NAME');
    default:
      return attributeI18nKey;
  }
};

const advancedFilterTypes = ref(
  advancedFilterOptions.map(filter => ({
    ...filter,
    attributeName: filterAttributeName(filter.attributeI18nKey),
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
const bulkServerSelection = useMapGetter('bulkActions/getServerSelection');
const appliedFilters = useMapGetter('getAppliedConversationFiltersV2');
const folders = useMapGetter('customViews/getConversationCustomViews');
const agentList = useMapGetter('agents/getAgents');
const teamsList = useMapGetter('teams/getTeams');
const inboxesList = useMapGetter('inboxes/getInboxes');
const campaigns = useMapGetter('campaigns/getAllCampaigns');
const labels = useMapGetter('labels/getLabels');
const currentAccountId = useMapGetter('getCurrentAccountId');
const getAccount = useMapGetter('accounts/getAccount');
const isFeatureEnabledonAccount = useMapGetter(
  'accounts/isFeatureEnabledonAccount'
);
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

const currentListContextKey = computed(() =>
  conversationListContextKey(route.query, { folderId: props.foldersId })
);

const showAiStatus = computed(() =>
  isFeatureEnabledonAccount.value(currentAccountId.value, FEATURE_FLAGS.CAPTAIN)
);

const isAssigneeSelectionLocked = computed(() =>
  isConversationAssigneeSelectionLocked(
    getAccount.value?.(currentAccountId.value)?.settings || {}
  )
);

const routeConversationStatus = computed(() => {
  const { status } = route.query;
  const savedStatus = conversationListContextState(
    uiSettings.value,
    currentListContextKey.value
  ).status;
  const resolvedStatus = sidebarStatuses.includes(status)
    ? status
    : savedStatus;

  return resolvedStatus === wootConstants.STATUS_TYPE.PENDING &&
    !showAiStatus.value
    ? wootConstants.STATUS_TYPE.OPEN
    : resolvedStatus;
});

const routeConversationAssigneeType = computed(() => {
  if (isAssigneeSelectionLocked.value) {
    return wootConstants.ASSIGNEE_TYPE.ALL;
  }

  const assigneeType = route.query.assignee_type || route.query.assigneeType;
  return Object.values(wootConstants.ASSIGNEE_TYPE).includes(assigneeType)
    ? assigneeType
    : wootConstants.ASSIGNEE_TYPE.ALL;
});

const truthyQueryValue = value =>
  value === true || value === 'true' || value === '1' || value === 1;

const activeUnreadOnly = computed(() =>
  truthyQueryValue(route.query.unread || route.query.unreadOnly)
);

function conversationNavigationQuery(overrides = {}) {
  const baseQuery = { ...route.query };
  const camelAssigneeType = baseQuery.assigneeType;
  const camelCrmPipelineId = baseQuery.crmPipelineId;
  const camelCrmStageId = baseQuery.crmStageId;
  const camelAppointmentStatus = baseQuery.appointmentStatus;
  const camelLabelsScope = baseQuery.labelsScope;
  const camelTeamScope = baseQuery.teamScope;
  const camelUnreadOnly = baseQuery.unreadOnly;
  delete baseQuery.messageId;
  delete baseQuery.assigneeType;
  delete baseQuery.crmPipelineId;
  delete baseQuery.crmStageId;
  delete baseQuery.appointmentStatus;
  delete baseQuery.labelsScope;
  delete baseQuery.teamScope;
  delete baseQuery.unreadOnly;

  const {
    assigneeType: overrideCamelAssigneeType,
    crmPipelineId: overrideCamelCrmPipelineId,
    crmStageId: overrideCamelCrmStageId,
    appointmentStatus: overrideCamelAppointmentStatus,
    labelsScope: overrideCamelLabelsScope,
    teamScope: overrideCamelTeamScope,
    unread: overrideUnread,
    unreadOnly: overrideUnreadOnly,
    ...safeOverrides
  } = overrides;
  const hasCrmPipelineOverride =
    Object.prototype.hasOwnProperty.call(safeOverrides, 'crm_pipeline_id') ||
    overrideCamelCrmPipelineId !== undefined;
  const hasCrmStageOverride =
    Object.prototype.hasOwnProperty.call(safeOverrides, 'crm_stage_id') ||
    overrideCamelCrmStageId !== undefined;
  const hasAppointmentStatusOverride =
    Object.prototype.hasOwnProperty.call(safeOverrides, 'appointment_status') ||
    overrideCamelAppointmentStatus !== undefined;
  const hasLabelsScopeOverride =
    Object.prototype.hasOwnProperty.call(safeOverrides, 'labels_scope') ||
    overrideCamelLabelsScope !== undefined;
  const hasTeamScopeOverride =
    Object.prototype.hasOwnProperty.call(safeOverrides, 'team_scope') ||
    overrideCamelTeamScope !== undefined;
  const hasUnreadOverride =
    overrideUnread !== undefined || overrideUnreadOnly !== undefined;
  const nextAssigneeType =
    safeOverrides.assignee_type ||
    overrideCamelAssigneeType ||
    baseQuery.assignee_type ||
    camelAssigneeType ||
    activeAssigneeTab.value;
  const nextCrmPipelineId = hasCrmPipelineOverride
    ? safeOverrides.crm_pipeline_id || overrideCamelCrmPipelineId
    : baseQuery.crm_pipeline_id || camelCrmPipelineId;
  const nextCrmStageId = hasCrmStageOverride
    ? safeOverrides.crm_stage_id || overrideCamelCrmStageId
    : baseQuery.crm_stage_id || camelCrmStageId;
  const nextAppointmentStatus = hasAppointmentStatusOverride
    ? safeOverrides.appointment_status || overrideCamelAppointmentStatus
    : baseQuery.appointment_status || camelAppointmentStatus;
  const nextLabelsScope = hasLabelsScopeOverride
    ? safeOverrides.labels_scope || overrideCamelLabelsScope
    : baseQuery.labels_scope || camelLabelsScope;
  const nextTeamScope = hasTeamScopeOverride
    ? safeOverrides.team_scope || overrideCamelTeamScope
    : baseQuery.team_scope || camelTeamScope;
  const nextUnread = hasUnreadOverride
    ? (overrideUnread ?? overrideUnreadOnly)
    : baseQuery.unread || camelUnreadOnly;
  const nextQuery = {
    ...baseQuery,
    ...safeOverrides,
    status: safeOverrides.status || activeStatus.value,
  };

  delete nextQuery.assigneeType;
  if (Object.values(wootConstants.ASSIGNEE_TYPE).includes(nextAssigneeType)) {
    nextQuery.assignee_type = nextAssigneeType;
  } else {
    delete nextQuery.assignee_type;
  }

  if (nextCrmPipelineId) {
    nextQuery.crm_pipeline_id = nextCrmPipelineId;
  } else {
    delete nextQuery.crm_pipeline_id;
  }

  if (nextCrmStageId) {
    nextQuery.crm_stage_id = nextCrmStageId;
  } else {
    delete nextQuery.crm_stage_id;
  }

  if (nextAppointmentStatus) {
    nextQuery.appointment_status = nextAppointmentStatus;
  } else {
    delete nextQuery.appointment_status;
  }

  if (nextLabelsScope) {
    nextQuery.labels_scope = nextLabelsScope;
  } else {
    delete nextQuery.labels_scope;
  }

  if (nextTeamScope) {
    nextQuery.team_scope = nextTeamScope;
  } else {
    delete nextQuery.team_scope;
  }

  if (truthyQueryValue(nextUnread)) {
    nextQuery.unread = 'true';
  } else {
    delete nextQuery.unread;
  }

  return nextQuery;
}

const routeTargetKey = ({
  name = route.name,
  params = route.params,
  query = route.query,
} = {}) => JSON.stringify({ name, params, query });

let expectedRouteTargetKey = routeTargetKey();

const currentUserDetails = computed(() => {
  const { id, name } = currentUser.value;
  return { id, name };
});

const filteredTabTotalCount = tabKey => {
  const countByTab = {
    [wootConstants.ASSIGNEE_TYPE.ME]: 'mineCount',
    [wootConstants.ASSIGNEE_TYPE.UNASSIGNED]: 'unAssignedCount',
    [wootConstants.ASSIGNEE_TYPE.ALL]: 'allCount',
  };
  const countKey = countByTab[tabKey];
  return Number(conversationStats.value[countKey] || 0);
};

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
const currentListTotal = useFunctionGetter(
  'conversationPage/getTotalCount',
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

const activeCrmPipelineId = computed(
  () => route.query.crm_pipeline_id || route.query.crmPipelineId || ''
);

const activeCrmStageId = computed(
  () => route.query.crm_stage_id || route.query.crmStageId || ''
);

const activeAppointmentStatusFilter = computed(() => {
  const status =
    route.query.appointment_status || route.query.appointmentStatus || '';

  if (status === APPOINTMENT_STATUS_ANY) {
    return APPOINTMENT_STATUS_ANY;
  }

  return APPOINTMENT_STATUS_VALUES.includes(status) ? status : '';
});

const activeAppointmentStatus = computed(() => {
  const status = activeAppointmentStatusFilter.value;
  return APPOINTMENT_STATUS_VALUES.includes(status) ? status : '';
});

const isFilteringAnyAppointmentStatus = computed(
  () => activeAppointmentStatusFilter.value === APPOINTMENT_STATUS_ANY
);

const appointmentStatusLabels = computed(() => ({
  cancelled: t('SCHEDULING.APPOINTMENT_STATUS.cancelled'),
  completed: t('SCHEDULING.APPOINTMENT_STATUS.completed'),
  confirmed: t('SCHEDULING.APPOINTMENT_STATUS.confirmed'),
  no_show: t('SCHEDULING.APPOINTMENT_STATUS.no_show'),
  scheduled: t('SCHEDULING.APPOINTMENT_STATUS.scheduled'),
}));

const activeAppointmentStatusLabel = computed(() => {
  if (isFilteringAnyAppointmentStatus.value) {
    return t('SCHEDULING.DIALOGS.SIDEBAR_TITLE');
  }

  return appointmentStatusLabels.value[activeAppointmentStatus.value] || '';
});

const activeLabelsScope = computed(
  () => route.query.labels_scope || route.query.labelsScope || ''
);

const activeTeamScope = computed(
  () => route.query.team_scope || route.query.teamScope || ''
);

const activeCrmPipeline = computed(() =>
  crmReferencesStore.pipelines.find(
    pipeline => String(pipeline.id) === String(activeCrmPipelineId.value)
  )
);

const activeCrmStage = computed(() =>
  (activeCrmPipeline.value?.stages || []).find(
    stage => String(stage.id) === String(activeCrmStageId.value)
  )
);

const defaultCrmPipelineStages = computed(() => {
  const { stages } = resolveDefaultPipelineWithStages(
    crmReferencesStore.pipelines
  );

  return stages.map(stage => ({
    id: stage.id,
    name: stage.name,
  }));
});

const activeAssigneeTabCount = computed(() => {
  return filteredTabTotalCount(activeAssigneeTab.value);
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
    communicationThreadMode: props.communicationThreadMode,
    crmPipelineId: activeCrmPipelineId.value || undefined,
    crmStageId: activeCrmStageId.value || undefined,
    appointmentStatus: activeAppointmentStatusFilter.value || undefined,
    labelsScope: props.label ? undefined : activeLabelsScope.value || undefined,
    teamScope: props.teamId ? undefined : activeTeamScope.value || undefined,
    unread: activeUnreadOnly.value || undefined,
  };
});

const activeLabelDisplayTitle = computed(() => {
  if (!props.label) return '';
  const label = labels.value.find(record => record.title === props.label);
  return labelDisplayTitle(label || props.label);
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
  if (activeCrmStage.value?.name) {
    return activeCrmStage.value.name;
  }
  if (activeCrmPipeline.value?.name) {
    return activeCrmPipeline.value.name;
  }
  if (activeCrmPipelineId.value || activeCrmStageId.value) {
    return t('SIDEBAR.PIPELINES');
  }
  if (activeAppointmentStatusLabel.value) {
    return activeAppointmentStatusLabel.value;
  }
  if (activeTeamScope.value === 'any') {
    return t('SIDEBAR.TEAMS');
  }
  if (activeLabelsScope.value === 'any') {
    return t('SIDEBAR.LABELS');
  }
  if (inbox.value.name) {
    return inbox.value.name;
  }
  if (activeTeam.value.name) {
    return activeTeam.value.name;
  }
  if (props.label) {
    return `#${activeLabelDisplayTitle.value}`;
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

  localConversationList = localConversationList.filter(conversation =>
    filterByUnread(true, activeUnreadOnly.value, conversation.unread_count)
  );

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

const shownConversationCount = computed(
  () => displayedConversationList.value.length
);

const totalConversationCount = computed(() => {
  if (hasLocalSearch.value) {
    return shownConversationCount.value;
  }

  if (props.communicationThreadMode) {
    return Number(currentListTotal.value || 0);
  }

  if (hasAppliedFiltersOrActiveFolders.value) {
    return conversationList.value.length;
  }

  return activeAssigneeTabCount.value;
});

const shouldShowListCountLabel = computed(() => {
  return totalConversationCount.value > 0 && shownConversationCount.value > 0;
});

const listCountLabel = computed(() => totalConversationCount.value);

const assignmentStatsFilters = computed(() => ({
  communicationThreadMode: true,
  status: activeStatus.value,
}));

function refreshAssignmentStats() {
  if (!props.communicationThreadMode) return;
  store.dispatch('conversationStats/get', assignmentStatsFilters.value);
}

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

const crmReferenceLoadFailed = ref(false);

// ---------------------- Methods -----------------------
function setFiltersFromUISettings() {
  const { order_by: orderBy } = conversationListContextState(
    uiSettings.value,
    currentListContextKey.value
  );
  activeStatus.value = routeConversationStatus.value;
  activeAssigneeTab.value = routeConversationAssigneeType.value;
  activeSortBy.value = Object.values(wootConstants.SORT_BY_TYPE).includes(
    orderBy
  )
    ? orderBy
    : wootConstants.SORT_BY_TYPE.LAST_ACTIVITY_AT_DESC;
}

async function ensureCrmReferencesLoaded({ force = false } = {}) {
  if (!force && !activeCrmPipelineId.value && !activeCrmStageId.value) {
    return true;
  }

  if (crmReferencesStore.pipelines.length) {
    crmReferenceLoadFailed.value = false;
    return true;
  }

  try {
    await crmReferencesStore.loadPipelines();
    crmReferenceLoadFailed.value = false;
    return true;
  } catch {
    crmReferenceLoadFailed.value = true;
    return false;
  }
}

async function normalizeCommunicationThreadRouteContext() {
  if (!props.communicationThreadMode) return;

  const referencesLoaded = await ensureCrmReferencesLoaded();
  if (!referencesLoaded) return;

  const queryUpdates = {};
  const requestedStatus = route.query.status;
  if (
    requestedStatus &&
    (!sidebarStatuses.includes(requestedStatus) ||
      (requestedStatus === wootConstants.STATUS_TYPE.PENDING &&
        !showAiStatus.value))
  ) {
    queryUpdates.crm_pipeline_id = undefined;
    queryUpdates.crm_stage_id = undefined;
    queryUpdates.appointment_status = undefined;
    queryUpdates.assignee_type = wootConstants.ASSIGNEE_TYPE.ALL;
    queryUpdates.status = conversationListContextState(
      uiSettings.value,
      `assignee:${wootConstants.ASSIGNEE_TYPE.ALL}`
    ).status;
  }

  if (activeCrmPipelineId.value || activeCrmStageId.value) {
    const selectionIsValid = isValidConversationPipelineSelection(
      resolveVisibleConversationPipelines(
        crmReferencesStore.pipelines,
        uiSettings.value
      ),
      activeCrmPipelineId.value,
      activeCrmStageId.value
    );
    if (!selectionIsValid) {
      queryUpdates.crm_pipeline_id = undefined;
      queryUpdates.crm_stage_id = undefined;
      queryUpdates.assignee_type = wootConstants.ASSIGNEE_TYPE.ALL;
      queryUpdates.status = conversationListContextState(
        uiSettings.value,
        `assignee:${wootConstants.ASSIGNEE_TYPE.ALL}`
      ).status;
    }
  }

  const requestedAppointmentStatus =
    route.query.appointment_status ?? route.query.appointmentStatus;
  if (
    requestedAppointmentStatus &&
    ![APPOINTMENT_STATUS_ANY, ...APPOINTMENT_STATUS_VALUES].includes(
      requestedAppointmentStatus
    )
  ) {
    queryUpdates.appointment_status = undefined;
    queryUpdates.crm_pipeline_id = undefined;
    queryUpdates.crm_stage_id = undefined;
    queryUpdates.assignee_type = wootConstants.ASSIGNEE_TYPE.ALL;
    queryUpdates.status = conversationListContextState(
      uiSettings.value,
      `assignee:${wootConstants.ASSIGNEE_TYPE.ALL}`
    ).status;
  }

  if (Object.keys(queryUpdates).length) {
    await router.replace({
      name: route.name,
      params: route.params,
      query: conversationNavigationQuery(queryUpdates),
    });
  }
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
    query: conversationNavigationQuery({ status: nextStatus }),
  });
}

function onUnreadFilterToggle() {
  router.push({
    name: route.name,
    params: route.params,
    query: conversationNavigationQuery({
      unread: !activeUnreadOnly.value,
    }),
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
      communicationThreadMode: props.communicationThreadMode,
      crmPipelineId: activeCrmPipelineId.value || undefined,
      crmStageId: activeCrmStageId.value || undefined,
      appointmentStatus: activeAppointmentStatusFilter.value || undefined,
      labelsScope: activeLabelsScope.value || undefined,
      teamScope: activeTeamScope.value || undefined,
      unread: activeUnreadOnly.value || undefined,
      sortBy: activeSortBy.value,
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
      communicationThreadMode: props.communicationThreadMode,
      crmPipelineId: activeCrmPipelineId.value || undefined,
      crmStageId: activeCrmStageId.value || undefined,
      appointmentStatus: activeAppointmentStatusFilter.value || undefined,
      labelsScope: activeLabelsScope.value || undefined,
      teamScope: activeTeamScope.value || undefined,
      unread: activeUnreadOnly.value || undefined,
      sortBy: activeSortBy.value,
    })
    .then(emitConversationLoaded);
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

function resetAndFetchData({ preserveAppliedFilters = false, status } = {}) {
  if (!preserveAppliedFilters) {
    appliedFilter.value = [];
    store.dispatch('clearConversationFilters');
  }
  resetBulkActions();
  store.dispatch('conversationPage/reset');
  if (hasActiveFolders.value) {
    const payload = activeFolder.value.query;
    fetchSavedFilteredConversations(payload);
  }
  if (props.foldersId) {
    return;
  }
  if (preserveAppliedFilters && hasAppliedFilters.value) {
    const filters = status
      ? mergeRouteStatusFilter(appliedFilters.value, status, sidebarStatuses)
      : appliedFilters.value;
    if (status) {
      store.dispatch('setConversationFilters', filters);
    }
    fetchFilteredConversations(filters);
    return;
  }
  fetchConversations();
}

async function resetConversationFilters() {
  const openStatus = wootConstants.STATUS_TYPE.OPEN;
  filterApplicationGeneration += 1;
  const resetGeneration = filterApplicationGeneration;
  const isCurrentReset = () => resetGeneration === filterApplicationGeneration;
  latestStatusRouteIntent = openStatus;
  await store.dispatch('invalidateConversationListRequests');
  if (!isCurrentReset()) return;

  appliedFilter.value = [];
  await store.dispatch('clearConversationFilters');
  if (!isCurrentReset()) return;

  if (route.query.status !== openStatus) {
    statusRouteSyncGeneration += 1;
    const syncGeneration = statusRouteSyncGeneration;
    const targetQuery = conversationNavigationQuery({ status: openStatus });
    expectedRouteTargetKey = routeTargetKey({ query: targetQuery });
    pendingStatusRouteSyncs.set(syncGeneration, {
      status: openStatus,
      applicationGeneration: resetGeneration,
      targetKey: expectedRouteTargetKey,
    });
    try {
      await router.replace({
        name: route.name,
        params: route.params,
        query: targetQuery,
      });
    } catch {
      if (isCurrentReset()) {
        clearLocalSearch();
        resetAndFetchData();
      }
      return;
    } finally {
      pendingStatusRouteSyncs.delete(syncGeneration);
    }
    if (!isCurrentReset()) return;
  }

  if (!isCurrentReset()) return;
  resetAndFetchData();
}

async function onApplyFilter(payload) {
  filterApplicationGeneration += 1;
  store.dispatch('invalidateConversationListRequests');
  const applicationGeneration = filterApplicationGeneration;
  payload = useSnakeCase(payload);

  const nextStatus = extractSingleStatusFilter(payload, sidebarStatuses);
  const targetStatus = nextStatus || routeConversationStatus.value;
  latestStatusRouteIntent = targetStatus;
  const hasConflictingPendingStatusSync = [
    ...pendingStatusRouteSyncs.values(),
  ].some(sync => sync.status !== targetStatus);
  if (
    targetStatus !== routeConversationStatus.value ||
    hasConflictingPendingStatusSync
  ) {
    statusRouteSyncGeneration += 1;
    const syncGeneration = statusRouteSyncGeneration;
    const targetQuery = conversationNavigationQuery({ status: targetStatus });
    expectedRouteTargetKey = routeTargetKey({ query: targetQuery });
    pendingStatusRouteSyncs.set(syncGeneration, {
      status: targetStatus,
      applicationGeneration,
      targetKey: expectedRouteTargetKey,
    });
    try {
      await router.replace({
        name: route.name,
        params: route.params,
        query: targetQuery,
      });
    } catch {
      pendingStatusRouteSyncs.delete(syncGeneration);
      if (applicationGeneration === filterApplicationGeneration) {
        filterApplicationGeneration += 1;
        clearLocalSearch();
        resetAndFetchData({
          preserveAppliedFilters: true,
          status: routeConversationStatus.value,
        });
      }
      return;
    } finally {
      pendingStatusRouteSyncs.delete(syncGeneration);
    }
  }

  if (applicationGeneration !== filterApplicationGeneration) {
    if (routeConversationStatus.value !== latestStatusRouteIntent) {
      statusRouteSyncGeneration += 1;
      const syncGeneration = statusRouteSyncGeneration;
      const targetQuery = conversationNavigationQuery({
        status: latestStatusRouteIntent,
      });
      expectedRouteTargetKey = routeTargetKey({ query: targetQuery });
      pendingStatusRouteSyncs.set(syncGeneration, {
        status: latestStatusRouteIntent,
        applicationGeneration: filterApplicationGeneration,
        targetKey: expectedRouteTargetKey,
      });
      try {
        await router.replace({
          name: route.name,
          params: route.params,
          query: targetQuery,
        });
      } finally {
        pendingStatusRouteSyncs.delete(syncGeneration);
      }
    }
    return;
  }

  resetBulkActions();
  foldersQuery.value = filterQueryGenerator(payload);
  store.dispatch('conversationPage/reset');
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
    crmStages: defaultCrmPipelineStages.value,
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
      queryOperator:
        normalizeFilterQueryOperator(transformed.queryOperator) ?? 'and',
      values,
    };
  });

  appliedFilter.value = [...appliedFilter.value, ...newFilters];
}

function initalizeAppliedFiltersToModal() {
  appliedFilter.value = [...appliedFilters.value];
}

async function onToggleAdvanceFiltersModal() {
  if (showAdvancedFilters.value === true) {
    closeAdvanceFiltersModal();
    return;
  }

  await ensureCrmReferencesLoaded({ force: true });

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
    fetchFilteredConversations(
      mergeRouteStatusFilter(
        appliedFilters.value,
        routeConversationStatus.value,
        sidebarStatuses
      )
    );
  }
}

// Use IntersectionObserver instead of @scroll since Virtualizer only emits on user scroll.
// If the list doesn’t fill the viewport, loading can stall.
// IntersectionObserver triggers as soon as the sentinel is visible.
const intersectionObserverOptions = computed(() => ({
  root: conversationListRef.value,
  rootMargin: '100px 0px 100px 0px',
}));

function onBasicFilterChange(value, type) {
  if (type === 'status') {
    updateConversationStatusQuery(value);
    return;
  }

  activeSortBy.value = value;
  updateUISettings({
    [CONVERSATION_LIST_CONTEXT_SETTINGS_KEY]:
      updatedConversationListContextSettings(
        uiSettings.value,
        currentListContextKey.value,
        { order_by: value }
      ),
  });
  resetAndFetchData();
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
      assigneeType: activeAssigneeTab.value,
      crmPipelineId: activeCrmPipelineId.value,
      crmStageId: activeCrmStageId.value,
      appointmentStatus: activeAppointmentStatusFilter.value,
      labelsScope: activeLabelsScope.value,
      teamScope: activeTeamScope.value,
      unread: activeUnreadOnly.value,
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
      conversationType: props.communicationThreadMode
        ? 'communication_thread'
        : 'conversation',
    });
    redirectToConversationList();
  } catch (error) {
    // Ignore error
  }
}
async function markAsRead(conversationId) {
  try {
    if (props.communicationThreadMode) {
      await store.dispatch('markCommunicationThreadRead', {
        id: conversationId,
      });
      return;
    }

    await store.dispatch('markMessagesRead', {
      id: conversationId,
    });
  } catch (error) {
    // Ignore error
  }
}

async function toggleConversationStatus(
  conversationId,
  status,
  snoozedUntil,
  customAttributes = null
) {
  const payload = {
    conversationId,
    status,
    snoozedUntil,
    conversationType: props.communicationThreadMode
      ? 'communication_thread'
      : 'conversation',
  };

  if (customAttributes) {
    payload.customAttributes = customAttributes;
  }

  try {
    await store.dispatch('toggleStatus', payload);
    useAlert(t('CONVERSATION.CHANGE_STATUS'));
  } catch (error) {
    useAlert(t('CONVERSATION.CHANGE_STATUS_FAILED'));
  }
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

function selectAllMatchingConversations() {
  if (!props.communicationThreadMode) return;

  const appliedFilterPayload = hasAppliedFilters.value
    ? filterQueryGenerator(useSnakeCase(appliedFilters.value)).payload
    : [];

  store.dispatch('bulkActions/setServerSelection', {
    mode: 'all_matching',
    filters: useSnakeCase(conversationFilters.value),
    payload: resolveBulkSelectionPayload({
      appliedFilterPayload,
      activeFolderQuery: activeFolder.value?.query,
    }),
    excluded_ids: [],
  });
}

useEmitter('fetch_conversation_stats', () => {
  if (hasAppliedFiltersOrActiveFolders.value) return;
  if (props.communicationThreadMode) {
    refreshAssignmentStats();
  } else {
    store.dispatch('conversationStats/get', conversationFilters.value);
  }
});

onMounted(async () => {
  store.dispatch('setChatListFilters', conversationFilters.value);
  setFiltersFromUISettings();
  await normalizeCommunicationThreadRouteContext();
  setFiltersFromUISettings();
  store.dispatch('setChatStatusFilter', activeStatus.value);
  store.dispatch('setChatSortFilter', activeSortBy.value);
  resetAndFetchData();
  refreshAssignmentStats();
  if (hasActiveFolders.value) {
    store.dispatch('campaigns/get');
  }
});

const deleteConversationDialogRef = ref(null);
const deleteCommunicationThreadDialogRef = ref(null);
const selectedConversationId = ref(null);
const selectedCommunicationThread = ref(null);
const isDeletingCommunicationThreadChannels = ref(false);

const selectedCommunicationThreadChannels = computed(() =>
  (selectedCommunicationThread.value?.channels || [])
    .map(channel => ({
      ...(channel || {}),
      conversation_id: Number(channel?.conversation_id),
    }))
    .filter(
      channel =>
        Number.isInteger(channel.conversation_id) && channel.conversation_id > 0
    )
);

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

async function deleteCommunicationThreadConversations(conversationIds) {
  if (!selectedCommunicationThread.value?.id || !conversationIds.length) return;

  const selectedIdSet = new Set(
    conversationIds.map(conversationId => String(conversationId))
  );
  const remainingChannelCount =
    selectedCommunicationThreadChannels.value.filter(
      channel => !selectedIdSet.has(String(channel.conversation_id))
    ).length;

  isDeletingCommunicationThreadChannels.value = true;
  try {
    await store.dispatch('deleteCommunicationThreadConversations', {
      threadId: selectedCommunicationThread.value.id,
      conversationIds,
    });
    if (!remainingChannelCount) {
      redirectToConversationList();
    }
    selectedCommunicationThread.value = null;
    deleteCommunicationThreadDialogRef.value?.close();
    useAlert(t('CONVERSATION.SUCCESS_DELETE_CONVERSATION'));
  } catch (error) {
    useAlert(t('CONVERSATION.FAIL_DELETE_CONVERSATION'));
  } finally {
    isDeletingCommunicationThreadChannels.value = false;
  }
}

const openCommunicationThreadDeleteDialog = async communicationThread => {
  selectedCommunicationThread.value = communicationThread;
  await loadCommunicationThreadDeleteDialog();
  await nextTick();
  deleteCommunicationThreadDialogRef.value?.open();
};

const handleDelete = async conversationId => {
  if (props.communicationThreadMode) {
    const communicationThread = getConversationById.value(
      conversationId,
      'communication_thread'
    );
    if (communicationThread?.is_communication_thread) {
      await openCommunicationThreadDeleteDialog(communicationThread);
      return;
    }
  }

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

watch(
  () => routeTargetKey(),
  (newTargetKey, oldTargetKey) => {
    if (
      newTargetKey === oldTargetKey ||
      newTargetKey === expectedRouteTargetKey
    ) {
      return;
    }

    const pendingTarget = [...pendingStatusRouteSyncs.values()].some(
      sync => sync.targetKey === newTargetKey
    );
    if (pendingTarget) return;

    latestStatusRouteIntent = routeConversationStatus.value;
    expectedRouteTargetKey = newTargetKey;
    filterApplicationGeneration += 1;
    store.dispatch('invalidateConversationListRequests');
  }
);

watch(routeConversationStatus, (newStatus, oldStatus) => {
  if (newStatus === oldStatus) {
    return;
  }

  activeStatus.value = newStatus;
  store.dispatch('setChatStatusFilter', newStatus);
  updateUISettings({
    [CONVERSATION_LIST_CONTEXT_SETTINGS_KEY]:
      updatedConversationListContextSettings(
        uiSettings.value,
        currentListContextKey.value,
        { status: newStatus, order_by: activeSortBy.value }
      ),
  });

  const matchingSyncGeneration = [...pendingStatusRouteSyncs.entries()].find(
    ([, sync]) =>
      sync.status === newStatus &&
      sync.applicationGeneration === filterApplicationGeneration
  )?.[0];
  if (matchingSyncGeneration !== undefined) {
    pendingStatusRouteSyncs.delete(matchingSyncGeneration);
    return;
  }

  const hasObsoleteStatusSync = [...pendingStatusRouteSyncs.values()].some(
    sync =>
      sync.status === newStatus &&
      sync.applicationGeneration < filterApplicationGeneration
  );
  if (hasObsoleteStatusSync && newStatus !== latestStatusRouteIntent) {
    return;
  }

  latestStatusRouteIntent = newStatus;
  filterApplicationGeneration += 1;
  clearLocalSearch();
  resetAndFetchData({
    preserveAppliedFilters: hasAppliedFilters.value,
    status: newStatus,
  });
  refreshAssignmentStats();
});

watch(currentListContextKey, () => {
  const { order_by: orderBy } = conversationListContextState(
    uiSettings.value,
    currentListContextKey.value
  );
  activeSortBy.value = orderBy;
  store.dispatch('setChatSortFilter', orderBy);
});

watch(routeConversationAssigneeType, (newAssigneeType, oldAssigneeType) => {
  if (newAssigneeType === oldAssigneeType) {
    return;
  }

  activeAssigneeTab.value = newAssigneeType;
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

watch([activeCrmPipelineId, activeCrmStageId], () => {
  ensureCrmReferencesLoaded();
  clearLocalSearch();
  resetAndFetchData();
});

watch(activeAppointmentStatusFilter, () => {
  clearLocalSearch();
  resetAndFetchData();
});

watch([activeLabelsScope, activeTeamScope], () => {
  clearLocalSearch();
  resetAndFetchData();
});

watch(activeUnreadOnly, () => {
  clearLocalSearch();
  resetAndFetchData();
});

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
      isOnExpandedLayout ? 'basis-full' : 'w-[320px] 2xl:w-[392px]',
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
      :active-unread-only="activeUnreadOnly"
      :active-status="activeStatus"
      :show-status-filter="communicationThreadMode"
      :show-ai-status="showAiStatus"
      :search-result-count="hasLocalSearch ? shownConversationCount : null"
      @add-folders="onClickOpenAddFoldersModal"
      @delete-folders="onClickOpenDeleteFoldersModal"
      @filters-modal="onToggleAdvanceFiltersModal"
      @reset-filters="resetConversationFilters"
      @basic-filter-change="onBasicFilterChange"
      @unread-filter-toggle="onUnreadFilterToggle"
      @status-filter-change="updateConversationStatusQuery"
    />

    <div
      v-if="crmReferenceLoadFailed"
      class="flex items-center justify-between gap-3 border-b border-n-weak bg-n-amber-2 px-4 py-2 text-xs text-n-slate-12"
    >
      <span>{{ $t('CRM.DEALS.PIPELINES_LOAD_ERROR') }}</span>
      <button
        type="button"
        class="shrink-0 font-medium text-n-brand hover:underline"
        @click="normalizeCommunicationThreadRouteContext"
      >
        {{ $t('CRM.DEALS.RETRY_LOAD') }}
      </button>
    </div>

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

    <p
      v-if="!chatListLoading && !conversationList.length && !hasLocalSearch"
      class="flex overflow-auto justify-center items-center p-4"
    >
      {{ $t('CHAT_LIST.LIST.404') }}
    </p>
    <ConversationBulkActions
      v-if="selectedConversations.length || bulkServerSelection"
      :conversations="selectedConversations"
      :all-conversations-selected="allConversationsSelected"
      :matching-conversation-count="
        communicationThreadMode
          ? totalConversationCount
          : displayedConversationList.length
      "
      :selectable-conversations-count="displayedConversationList.length"
      :selected-inboxes="uniqueInboxes"
      :show-open-action="allSelectedConversationsStatus('open')"
      :show-resolved-action="allSelectedConversationsStatus('resolved')"
      :show-snoozed-action="allSelectedConversationsStatus('snoozed')"
      @select-all-conversations="toggleSelectAll"
      @select-all-matching="selectAllMatchingConversations"
      @assign-agent="handleAssignAgent"
      @update-conversations="
        (status, snoozedUntil, statusReason) =>
          onUpdateConversations(
            status,
            snoozedUntil,
            communicationThreadMode,
            statusReason
          )
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
          :active-assignee-type="activeAssigneeTab"
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
      <div
        v-if="shouldShowListCountLabel"
        class="sticky bottom-3 z-20 flex justify-center pointer-events-none"
      >
        <span
          class="rounded-full bg-n-alpha-1 px-2 py-1 text-xs font-medium text-n-slate-11 shadow-sm backdrop-blur"
        >
          {{ listCountLabel }}
        </span>
      </div>
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
    <CommunicationThreadDeleteDialog
      ref="deleteCommunicationThreadDialogRef"
      :thread-id="selectedCommunicationThread?.id"
      :channels="selectedCommunicationThreadChannels"
      :is-loading="isDeletingCommunicationThreadChannels"
      @confirm="deleteCommunicationThreadConversations"
      @close="selectedCommunicationThread = null"
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
