<script setup>
import { h, ref, computed, onMounted, onBeforeUnmount, watch } from 'vue';
import { useRoute, useRouter } from 'vue-router';
import { provideSidebarContext } from './provider';
import { useAccount } from 'dashboard/composables/useAccount';
import { usePolicy } from 'dashboard/composables/usePolicy';
import { useUISettings } from 'dashboard/composables/useUISettings';
import { useKbd } from 'dashboard/composables/utils/useKbd';
import { useMapGetter } from 'dashboard/composables/store';
import { useStore } from 'vuex';
import { useI18n } from 'vue-i18n';
import { useSidebarKeyboardShortcuts } from './useSidebarKeyboardShortcuts';
import { vOnClickOutside } from '@vueuse/components';
import { FEATURE_FLAGS } from 'dashboard/featureFlags';
import { useWindowSize, useEventListener } from '@vueuse/core';
import { emitter } from 'shared/helpers/mitt';
import { BUS_EVENTS } from 'shared/constants/busEvents';

import SidebarGroup from './SidebarGroup.vue';
import SidebarSecondaryColumn from './SidebarSecondaryColumn.vue';
import SidebarProfileMenu from './SidebarProfileMenu.vue';
import SidebarChangelogCard from './SidebarChangelogCard.vue';
import SidebarChangelogButton from './SidebarChangelogButton.vue';
import SidebarAccountSwitcher from './SidebarAccountSwitcher.vue';
import ComposeConversation from 'dashboard/components-next/NewConversation/ComposeConversation.vue';
import AddLabelForm from 'dashboard/routes/dashboard/settings/labels/AddLabel.vue';
import {
  labelDisplayTitle,
  labelMarkerColor,
  labelMarkerEmoji,
  labelMarkerType,
} from 'dashboard/helper/labels';
import {
  CONVERSATION_APPOINTMENT_STATUSES_VISIBILITY_KEY,
  CONVERSATION_APPOINTMENT_STATUS_VISIBILITY_KEYS,
  buildEffectiveSidebarVisibilitySettings,
  filterSidebarMenuItems,
} from './sidebarVisibility';
import { ASSIGNEE_TYPE_TAB_PERMISSIONS } from 'dashboard/constants/permissions';
import wootConstants from 'dashboard/constants/globals';
import {
  filterItemsByPermission,
  getUserPermissions,
} from 'dashboard/helper/permissionsHelper';
import {
  getInboxFlowRouteNames,
  INBOX_FLOW_ROUTE_NAMES,
} from 'dashboard/routes/dashboard/settings/inbox/helpers/inboxFlowRoutes';
import { employeeSettingsTabs } from 'dashboard/routes/dashboard/settings/employeeSettingsTabs';
import { WORKSPACE_SETTINGS_ACTIVE_ROUTE_NAMES } from 'dashboard/routes/dashboard/settings/workspaceSettingsTabs';
import { canAccessSLASettings } from 'dashboard/routes/dashboard/settings/sla/slaSettingsPolicy';
import {
  isInboxPendingDeletion,
  isWhatsappWebInbox,
  isWhatsappWebConnected,
} from 'dashboard/helper/whatsappWeb';
import {
  isTelegramPersonalInbox,
  isTelegramPersonalConnected,
} from 'dashboard/helper/telegramPersonal';
import { useCrmReferencesStore } from 'dashboard/stores/crm/references';
import { resolveVisibleConversationPipelines } from './conversationPipelineVisibility';
import {
  APPOINTMENT_STATUS_ICON_CLASSES,
  APPOINTMENT_STATUS_ICONS,
  APPOINTMENT_STATUS_VALUES,
} from 'dashboard/routes/dashboard/scheduling/constants';
import { conversationListContextState } from 'dashboard/helper/conversationListContext';

const props = defineProps({
  isMobileSidebarOpen: {
    type: Boolean,
    default: false,
  },
});

const emit = defineEmits([
  'closeKeyShortcutModal',
  'openKeyShortcutModal',
  'showCreateAccountModal',
  'closeMobileSidebar',
]);

const SIDEBAR_RUNTIME_HEALTHY_POLL_INTERVAL_MS = 60 * 1000;
const SIDEBAR_RUNTIME_ATTENTION_POLL_INTERVAL_MS = 15 * 1000;

const { accountScopedRoute, currentAccount, isOnChatwootCloud } = useAccount();
const route = useRoute();
const router = useRouter();
const { checkPermissions, shouldShow } = usePolicy();
const store = useStore();
const crmReferencesStore = useCrmReferencesStore();
const searchShortcut = useKbd([`$mod`, 'k']);
const { t } = useI18n();
const { uiSettings } = useUISettings();
const composeConversationRef = ref(null);

const effectiveSidebarVisibilitySettings = computed(() =>
  buildEffectiveSidebarVisibilitySettings({
    accountId: currentAccount.value?.id,
    accountSettings: currentAccount.value?.settings || {},
    uiSettings: uiSettings.value,
  })
);

const isACustomBrandedInstance = useMapGetter(
  'globalConfig/isACustomBrandedInstance'
);

const { width: windowWidth } = useWindowSize();
const isMobile = computed(() => windowWidth.value < 768);
const DESKTOP_RAIL_WIDTH = 44;
const DESKTOP_SECONDARY_COLUMN_WIDTH = 178;
const COMPANY_ACTIVE_ROUTE_NAMES = [
  'companies_dashboard_index',
  'companies_dashboard_show',
];

const accountId = useMapGetter('getCurrentAccountId');
const currentUser = useMapGetter('getCurrentUser');
const isFeatureEnabledonAccount = useMapGetter(
  'accounts/isFeatureEnabledonAccount'
);

const hasSchedulingSettings = computed(() => {
  return isFeatureEnabledonAccount.value(
    accountId.value,
    FEATURE_FLAGS.SCHEDULING
  );
});

const hasInboxManagement = computed(() => {
  return isFeatureEnabledonAccount.value(
    accountId.value,
    FEATURE_FLAGS.INBOX_MANAGEMENT
  );
});

const hasCommunicationThreads = computed(() => {
  return isFeatureEnabledonAccount.value(
    accountId.value,
    FEATURE_FLAGS.COMMUNICATION_THREADS
  );
});

const hasCrmDeals = computed(() => {
  return isFeatureEnabledonAccount.value(
    accountId.value,
    FEATURE_FLAGS.CRM_DEALS
  );
});

const hasCrmTasks = computed(() => {
  return isFeatureEnabledonAccount.value(
    accountId.value,
    FEATURE_FLAGS.CRM_TASKS
  );
});

const hasSLA = computed(() => {
  return canAccessSLASettings(shouldShow);
});

const hasAutomationRules = computed(() => {
  return (
    checkPermissions(['administrator']) &&
    isFeatureEnabledonAccount.value(accountId.value, FEATURE_FLAGS.AUTOMATIONS)
  );
});

const hasAssignmentPolicies = computed(() => {
  return (
    checkPermissions(['administrator']) &&
    isFeatureEnabledonAccount.value(
      accountId.value,
      FEATURE_FLAGS.ASSIGNMENT_V2
    )
  );
});

const hasAuditLogs = computed(() => {
  return (
    checkPermissions(['administrator']) &&
    isFeatureEnabledonAccount.value(accountId.value, FEATURE_FLAGS.AUDIT_LOGS)
  );
});

const hasSettingsAccess = computed(() => {
  return checkPermissions(['administrator']);
});

const hasCrmSettingsAccess = computed(() => {
  return checkPermissions(['crm_settings_view', 'crm_settings_manage']);
});

const hasCompanies = computed(() => {
  return isFeatureEnabledonAccount.value(
    accountId.value,
    FEATURE_FLAGS.COMPANIES
  );
});

const hasLegacyCustomAttributes = computed(() => {
  return (
    checkPermissions(['administrator']) &&
    isFeatureEnabledonAccount.value(
      accountId.value,
      FEATURE_FLAGS.CUSTOM_ATTRIBUTES
    )
  );
});

const toggleShortcutModalFn = show => {
  if (show) {
    emit('openKeyShortcutModal');
  } else {
    emit('closeKeyShortcutModal');
  }
};

useSidebarKeyboardShortcuts(toggleShortcutModalFn);

const expandedItem = ref(null);
const showCreateLabelPopup = ref(false);

const openCreateLabelPopup = () => {
  showCreateLabelPopup.value = true;
};

const hideCreateLabelPopup = () => {
  showCreateLabelPopup.value = false;
};

const setExpandedItem = name => {
  expandedItem.value = expandedItem.value === name ? null : name;
};

const sidebarWidth = computed(() =>
  isMobile.value ? 200 : DESKTOP_RAIL_WIDTH
);
const isEffectivelyCollapsed = computed(() => !isMobile.value);

provideSidebarContext({
  expandedItem,
  setExpandedItem,
  isCollapsed: isEffectivelyCollapsed,
  sidebarWidth,
});

const inboxes = useMapGetter('inboxes/getInboxes');
const labels = useMapGetter('labels/getLabelsOnSidebar');
const teams = useMapGetter('teams/getMyTeams');
const contactCustomViews = useMapGetter('customViews/getContactCustomViews');
const conversationCustomViews = useMapGetter(
  'customViews/getConversationCustomViews'
);

const conversationStats = useMapGetter('conversationStats/getStats');

const sortedInboxes = computed(() =>
  inboxes.value.slice().sort((a, b) => a.name.localeCompare(b.name))
);
const selectedConversation = useMapGetter('getSelectedChat');

const conversationStatuses = ['pending', 'open', 'snoozed', 'resolved'];
const conversationAssigneeTypes = [
  wootConstants.ASSIGNEE_TYPE.ALL,
  wootConstants.ASSIGNEE_TYPE.ME,
  wootConstants.ASSIGNEE_TYPE.UNASSIGNED,
];
const isDialogConversationRoute = routeName =>
  typeof routeName === 'string' &&
  (routeName === 'home' ||
    routeName === 'inbox_dashboard' ||
    routeName.startsWith('communication_thread') ||
    routeName.startsWith('conversation') ||
    routeName.startsWith('conversations'));

const conversationStatusActiveOn = [
  'home',
  'inbox_dashboard',
  'inbox_conversation',
  'conversation_through_inbox',
  'communication_threads_dashboard',
  'communication_thread_conversation',
  'label_conversations',
  'conversations_through_label',
  'team_conversations',
  'conversations_through_team',
  'folder_conversations',
  'conversations_through_folders',
];

const normalizeConversationStatus = status => {
  const normalizedStatus = String(status || '').toLowerCase();
  return conversationStatuses.includes(normalizedStatus)
    ? normalizedStatus
    : '';
};

const routeHasSelectedConversationContext = computed(() =>
  Boolean(
    route.params?.conversation_id ||
      route.params?.conversationId ||
      route.params?.communication_thread_id
  )
);

const currentConversationStatus = computed(() => {
  const selectedStatus = normalizeConversationStatus(
    selectedConversation.value?.status
  );

  if (routeHasSelectedConversationContext.value && selectedStatus) {
    return selectedStatus;
  }

  return (
    normalizeConversationStatus(route.query.status) || selectedStatus || 'open'
  );
});

const currentConversationAssigneeType = computed(() => {
  const assigneeType = route.query.assignee_type || route.query.assigneeType;

  return conversationAssigneeTypes.includes(assigneeType)
    ? assigneeType
    : wootConstants.ASSIGNEE_TYPE.ALL;
});

const currentAppointmentStatusFilter = computed(
  () => route.query.appointment_status || route.query.appointmentStatus || ''
);

const currentAppointmentStatus = computed(() => {
  const status = currentAppointmentStatusFilter.value;
  return APPOINTMENT_STATUS_VALUES.includes(status) ? status : '';
});

const truthyQueryValue = value =>
  value === true || value === 'true' || value === '1' || value === 1;

const conversationNavigationQuery = (overrides = {}) => {
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
    currentConversationAssigneeType.value;
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
    status: safeOverrides.status || currentConversationStatus.value,
  };

  if (conversationAssigneeTypes.includes(nextAssigneeType)) {
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
};

const resolveConversationRouteName = name => {
  if (name === 'home' && hasCommunicationThreads.value) {
    return 'communication_threads_dashboard';
  }

  return name;
};

const conversationSidebarRoute = computed(() => {
  if (isDialogConversationRoute(route.name)) {
    return true;
  }

  return (
    route.name === INBOX_FLOW_ROUTE_NAMES.dialog.show ||
    route.name === INBOX_FLOW_ROUTE_NAMES.dialog.new ||
    route.name === INBOX_FLOW_ROUTE_NAMES.dialog.agents ||
    route.name === INBOX_FLOW_ROUTE_NAMES.dialog.page ||
    route.name === INBOX_FLOW_ROUTE_NAMES.dialog.finish
  );
});

const currentConversationScope = computed(() => {
  switch (route.name) {
    case 'inbox_conversation': {
      const selectedConversationInboxId = Number(
        selectedConversation.value?.inbox_id
      );

      if (
        Number.isFinite(selectedConversationInboxId) &&
        selectedConversationInboxId > 0
      ) {
        return {
          name: 'inbox_dashboard',
          params: { inbox_id: selectedConversationInboxId },
        };
      }

      return {
        name: 'home',
        params: {},
      };
    }
    case 'inbox_dashboard':
    case 'conversation_through_inbox':
      return {
        name: 'inbox_dashboard',
        params: { inbox_id: route.params.inbox_id },
      };
    case 'communication_threads_dashboard':
    case 'communication_thread_conversation':
      return {
        name: 'communication_threads_dashboard',
        params: {},
      };
    case 'label_conversations':
    case 'conversations_through_label':
      return {
        name: 'label_conversations',
        params: { label: route.params.label },
      };
    case 'team_conversations':
    case 'conversations_through_team':
      return {
        name: 'team_conversations',
        params: { teamId: route.params.teamId },
      };
    case 'folder_conversations':
    case 'conversations_through_folders':
      return {
        name: 'folder_conversations',
        params: { id: route.params.id },
      };
    case INBOX_FLOW_ROUTE_NAMES.dialog.show: {
      const selectedInboxId = Number(
        route.params.inboxId || route.params.inbox_id
      );

      if (Number.isFinite(selectedInboxId) && selectedInboxId > 0) {
        return {
          name: 'inbox_dashboard',
          params: { inbox_id: selectedInboxId },
        };
      }

      return {
        name: 'home',
        params: {},
      };
    }
    default:
      return {
        name: 'home',
        params: {},
      };
  }
});

const inboxFlowRouteNames = computed(() =>
  conversationSidebarRoute.value
    ? INBOX_FLOW_ROUTE_NAMES.dialog
    : getInboxFlowRouteNames(route)
);

const hasDedicatedInboxRuntimePolling = computed(() => {
  return route.name === inboxFlowRouteNames.value.finish;
});

const dedicatedRuntimePollingInboxId = computed(() => {
  if (!hasDedicatedInboxRuntimePolling.value) {
    return null;
  }

  const inboxId = Number(route.params.inboxId || route.params.inbox_id);
  return Number.isFinite(inboxId) && inboxId > 0 ? inboxId : null;
});

const withConversationStatus = (name, params = {}, queryOverrides = {}) =>
  accountScopedRoute(
    resolveConversationRouteName(name),
    params,
    conversationNavigationQuery(queryOverrides)
  );

const withCurrentConversationScopeAssigneeType = assigneeType =>
  accountScopedRoute(
    resolveConversationRouteName(currentConversationScope.value.name),
    currentConversationScope.value.params,
    conversationNavigationQuery({
      assignee_type: assigneeType,
      crm_pipeline_id: undefined,
      crm_stage_id: undefined,
      appointment_status: undefined,
      status: conversationListContextState(
        uiSettings.value,
        `assignee:${assigneeType}`
      ).status,
    })
  );

const hasRouteLabelsScopeAny = () => {
  const labelsScope = route.query.labels_scope ?? route.query.labelsScope;
  return (
    String(labelsScope || '') === 'any' &&
    !['label_conversations', 'conversations_through_label'].includes(route.name)
  );
};

const hasRouteTeamScopeAny = () => {
  const teamScope = route.query.team_scope ?? route.query.teamScope;
  return (
    String(teamScope || '') === 'any' &&
    !['team_conversations', 'conversations_through_team'].includes(route.name)
  );
};

const withLabelsScopeToggle = () =>
  hasRouteLabelsScopeAny()
    ? withConversationStatus('home', {}, { labels_scope: undefined })
    : withConversationStatus(
        'home',
        {},
        {
          labels_scope: 'any',
          team_scope: undefined,
        }
      );

const withTeamScopeToggle = () =>
  hasRouteTeamScopeAny()
    ? withConversationStatus('home', {}, { team_scope: undefined })
    : withConversationStatus(
        'home',
        {},
        {
          labels_scope: undefined,
          team_scope: 'any',
        }
      );

const withCurrentConversationScopeCrmStage = (pipelineId, stageId) =>
  accountScopedRoute(
    resolveConversationRouteName(currentConversationScope.value.name),
    currentConversationScope.value.params,
    conversationNavigationQuery({
      crm_pipeline_id: pipelineId,
      crm_stage_id: stageId,
      appointment_status: undefined,
      assignee_type: wootConstants.ASSIGNEE_TYPE.ALL,
      status: conversationListContextState(
        uiSettings.value,
        `crm-stage:${stageId}`
      ).status,
    })
  );

const withCurrentConversationScopeAppointmentStatus = status =>
  accountScopedRoute(
    resolveConversationRouteName(currentConversationScope.value.name),
    currentConversationScope.value.params,
    conversationNavigationQuery({
      appointment_status:
        currentAppointmentStatus.value === status ? undefined : status,
      crm_pipeline_id: undefined,
      crm_stage_id: undefined,
      assignee_type: wootConstants.ASSIGNEE_TYPE.ALL,
      status: conversationListContextState(
        uiSettings.value,
        currentAppointmentStatus.value === status
          ? `assignee:${wootConstants.ASSIGNEE_TYPE.ALL}`
          : `appointment:${status}`
      ).status,
    })
  );

const appointmentStatusLabels = computed(() => ({
  cancelled: t('SCHEDULING.APPOINTMENT_STATUS.cancelled'),
  completed: t('SCHEDULING.APPOINTMENT_STATUS.completed'),
  confirmed: t('SCHEDULING.APPOINTMENT_STATUS.confirmed'),
  no_show: t('SCHEDULING.APPOINTMENT_STATUS.no_show'),
  scheduled: t('SCHEDULING.APPOINTMENT_STATUS.scheduled'),
}));

const appointmentStatusSidebarLabels = computed(() => ({
  cancelled: appointmentStatusLabels.value.cancelled,
  completed: t('SCHEDULING.DIALOGS.APPOINTMENT_STATUS_SHORT.completed'),
  confirmed: t('SCHEDULING.DIALOGS.APPOINTMENT_STATUS_SHORT.confirmed'),
  no_show: appointmentStatusLabels.value.no_show,
  scheduled: t('SCHEDULING.DIALOGS.APPOINTMENT_STATUS_SHORT.scheduled'),
}));

const appointmentStatusSidebarItems = computed(() => {
  if (!hasSchedulingSettings.value) {
    return [];
  }

  return [
    {
      name: 'AppointmentStatuses',
      visibilityKey: CONVERSATION_APPOINTMENT_STATUSES_VISIBILITY_KEY,
      label: t('SCHEDULING.DIALOGS.SIDEBAR_TITLE'),
      icon: 'i-lucide-calendar-clock',
      suppressHeaderActiveWhenChildActive: true,
      children: APPOINTMENT_STATUS_VALUES.map(status => ({
        name: `AppointmentStatus:${status}`,
        visibilityKey: CONVERSATION_APPOINTMENT_STATUS_VISIBILITY_KEYS[status],
        label: appointmentStatusSidebarLabels.value[status] || status,
        icon: APPOINTMENT_STATUS_ICONS[status],
        iconClass: APPOINTMENT_STATUS_ICON_CLASSES[status],
        labelClass: APPOINTMENT_STATUS_ICON_CLASSES[status],
        countClass: APPOINTMENT_STATUS_ICON_CLASSES[status],
        active: currentAppointmentStatus.value === status,
        activeOn: conversationStatusActiveOn,
        to: withCurrentConversationScopeAppointmentStatus(status),
      })),
    },
  ];
});

const crmPipelineSidebarItems = computed(() => {
  if (!hasCrmDeals.value) {
    return [];
  }

  return resolveVisibleConversationPipelines(
    crmReferencesStore.pipelines,
    currentAccount.value?.settings || {}
  ).map(pipeline => ({
    name: `Pipeline:${pipeline.id}`,
    visibilityKey: 'Conversation:Pipelines',
    label: pipeline.name || t('SIDEBAR.PIPELINES'),
    icon: 'i-lucide-filter',
    suppressHeaderActiveWhenChildActive: true,
    children: pipeline.stages.map(stage => ({
      name: `PipelineStage:${pipeline.id}:${stage.id}`,
      label: stage.name,
      connectorColor: stage.color,
      activeOn: conversationStatusActiveOn,
      to: withCurrentConversationScopeCrmStage(pipeline.id, stage.id),
    })),
  }));
});

const userPermissions = computed(() =>
  getUserPermissions(currentUser.value, accountId.value)
);

const conversationAssigneeStatusIcons = {
  [wootConstants.ASSIGNEE_TYPE.ME]: 'i-lucide-user-round-check',
  [wootConstants.ASSIGNEE_TYPE.ALL]: 'i-lucide-users-round',
  [wootConstants.ASSIGNEE_TYPE.UNASSIGNED]: 'i-lucide-user-round-x',
};

const conversationAssigneeStatusLabels = computed(() => ({
  [wootConstants.ASSIGNEE_TYPE.ME]: t('CHAT_LIST.ASSIGNEE_TYPE_TABS.me'),
  [wootConstants.ASSIGNEE_TYPE.ALL]: t('CHAT_LIST.ASSIGNEE_TYPE_TABS.all'),
  [wootConstants.ASSIGNEE_TYPE.UNASSIGNED]: t(
    'CHAT_LIST.ASSIGNEE_TYPE_TABS.unassigned'
  ),
}));

const conversationAssigneeStatusItems = computed(() =>
  filterItemsByPermission(
    conversationAssigneeTypes.reduce((items, key) => {
      items[key] = ASSIGNEE_TYPE_TAB_PERMISSIONS[key];
      return items;
    }, {}),
    userPermissions.value,
    item => item.permissions
  ).map(({ key }) => {
    const countByTab = {
      [wootConstants.ASSIGNEE_TYPE.ME]: conversationStats.value?.mineCount,
      [wootConstants.ASSIGNEE_TYPE.ALL]: conversationStats.value?.allCount,
      [wootConstants.ASSIGNEE_TYPE.UNASSIGNED]:
        conversationStats.value?.unAssignedCount,
    };
    const unreadCountByTab = {
      [wootConstants.ASSIGNEE_TYPE.ME]:
        conversationStats.value?.mineUnreadCount,
      [wootConstants.ASSIGNEE_TYPE.ALL]:
        conversationStats.value?.allUnreadCount,
      [wootConstants.ASSIGNEE_TYPE.UNASSIGNED]:
        conversationStats.value?.unAssignedUnreadCount,
    };

    return {
      name: `Assignee:${key}`,
      visibilityKey: `Conversation:Assignee:${key}`,
      label: conversationAssigneeStatusLabels.value[key],
      icon: conversationAssigneeStatusIcons[key],
      count: Number(countByTab[key] || 0),
      hasUnread: Number(unreadCountByTab[key] || 0) > 0,
      activeOn: conversationStatusActiveOn,
      to: withCurrentConversationScopeAssigneeType(key),
    };
  })
);

const whatsappWebInboxes = computed(() => {
  return sortedInboxes.value.filter(
    inbox => isWhatsappWebInbox(inbox) && !isInboxPendingDeletion(inbox)
  );
});

const whatsappWebHealthyInboxes = computed(() => {
  return whatsappWebInboxes.value.filter(inbox =>
    isWhatsappWebConnected(inbox)
  );
});

const whatsappWebAttentionInboxes = computed(() => {
  return whatsappWebInboxes.value.filter(
    inbox => !isWhatsappWebConnected(inbox)
  );
});

const telegramPersonalInboxes = computed(() => {
  return sortedInboxes.value.filter(inbox => isTelegramPersonalInbox(inbox));
});

const telegramPersonalHealthyInboxes = computed(() => {
  return telegramPersonalInboxes.value.filter(inbox =>
    isTelegramPersonalConnected(inbox)
  );
});

const telegramPersonalAttentionInboxes = computed(() => {
  return telegramPersonalInboxes.value.filter(
    inbox => !isTelegramPersonalConnected(inbox)
  );
});

const excludeDedicatedRuntimePollingInbox = inboxList => {
  if (!dedicatedRuntimePollingInboxId.value) {
    return inboxList;
  }

  return inboxList.filter(
    inbox => Number(inbox.id) !== dedicatedRuntimePollingInboxId.value
  );
};

const sidebarWhatsappWebHealthyInboxes = computed(() =>
  excludeDedicatedRuntimePollingInbox(whatsappWebHealthyInboxes.value)
);

const sidebarWhatsappWebAttentionInboxes = computed(() =>
  excludeDedicatedRuntimePollingInbox(whatsappWebAttentionInboxes.value)
);

const sidebarTelegramPersonalHealthyInboxes = computed(() =>
  excludeDedicatedRuntimePollingInbox(telegramPersonalHealthyInboxes.value)
);

const sidebarTelegramPersonalAttentionInboxes = computed(() =>
  excludeDedicatedRuntimePollingInbox(telegramPersonalAttentionInboxes.value)
);

const canManageWhatsappWebLifecycle = computed(() => {
  return checkPermissions(['administrator']);
});

const sidebarRuntimePollingTimers = {
  whatsappHealthy: null,
  whatsappAttention: null,
  telegramHealthy: null,
  telegramAttention: null,
};

const isSidebarRuntimePollingAllowed = () => {
  if (typeof document === 'undefined') {
    return true;
  }

  return document.visibilityState === 'visible';
};

const stopSidebarRuntimePollingTimer = key => {
  if (!sidebarRuntimePollingTimers[key]) {
    return;
  }

  window.clearInterval(sidebarRuntimePollingTimers[key]);
  sidebarRuntimePollingTimers[key] = null;
};

const stopSidebarRuntimePolling = () => {
  Object.keys(sidebarRuntimePollingTimers).forEach(
    stopSidebarRuntimePollingTimer
  );
};

const startSidebarRuntimePollingTimer = (key, callback, interval) => {
  if (sidebarRuntimePollingTimers[key]) {
    return;
  }

  sidebarRuntimePollingTimers[key] = window.setInterval(callback, interval);
};

const syncWhatsappWebStatuses = async inboxList => {
  if (
    !canManageWhatsappWebLifecycle.value ||
    !isSidebarRuntimePollingAllowed() ||
    !inboxList.length
  ) {
    return;
  }

  await Promise.allSettled(
    inboxList.map(inbox =>
      store.dispatch('inboxes/refreshWhatsappWebQr', {
        inboxId: inbox.id,
        statusOnly: true,
        includeQrCode: false,
      })
    )
  );
};

const syncTelegramPersonalStatuses = async inboxList => {
  if (!isSidebarRuntimePollingAllowed() || !inboxList.length) {
    return;
  }

  await Promise.allSettled(
    inboxList.map(inbox =>
      store.dispatch('inboxes/getTelegramPersonalDiagnostics', inbox.id)
    )
  );
};

const syncSidebarRuntimePolling = () => {
  stopSidebarRuntimePolling();

  if (!isSidebarRuntimePollingAllowed()) {
    return;
  }

  if (canManageWhatsappWebLifecycle.value) {
    if (sidebarWhatsappWebHealthyInboxes.value.length) {
      syncWhatsappWebStatuses(sidebarWhatsappWebHealthyInboxes.value);
      startSidebarRuntimePollingTimer(
        'whatsappHealthy',
        () => syncWhatsappWebStatuses(sidebarWhatsappWebHealthyInboxes.value),
        SIDEBAR_RUNTIME_HEALTHY_POLL_INTERVAL_MS
      );
    }

    if (sidebarWhatsappWebAttentionInboxes.value.length) {
      syncWhatsappWebStatuses(sidebarWhatsappWebAttentionInboxes.value);
      startSidebarRuntimePollingTimer(
        'whatsappAttention',
        () => syncWhatsappWebStatuses(sidebarWhatsappWebAttentionInboxes.value),
        SIDEBAR_RUNTIME_ATTENTION_POLL_INTERVAL_MS
      );
    }
  }

  if (sidebarTelegramPersonalHealthyInboxes.value.length) {
    syncTelegramPersonalStatuses(sidebarTelegramPersonalHealthyInboxes.value);
    startSidebarRuntimePollingTimer(
      'telegramHealthy',
      () =>
        syncTelegramPersonalStatuses(
          sidebarTelegramPersonalHealthyInboxes.value
        ),
      SIDEBAR_RUNTIME_HEALTHY_POLL_INTERVAL_MS
    );
  }

  if (sidebarTelegramPersonalAttentionInboxes.value.length) {
    syncTelegramPersonalStatuses(sidebarTelegramPersonalAttentionInboxes.value);
    startSidebarRuntimePollingTimer(
      'telegramAttention',
      () =>
        syncTelegramPersonalStatuses(
          sidebarTelegramPersonalAttentionInboxes.value
        ),
      SIDEBAR_RUNTIME_ATTENTION_POLL_INTERVAL_MS
    );
  }
};

const handleSidebarRuntimeVisibilityChange = () => {
  syncSidebarRuntimePolling();
};

useEventListener(
  document,
  'visibilitychange',
  handleSidebarRuntimeVisibilityChange
);

watch(
  () =>
    [
      canManageWhatsappWebLifecycle.value,
      hasDedicatedInboxRuntimePolling.value,
      dedicatedRuntimePollingInboxId.value,
      sidebarWhatsappWebHealthyInboxes.value.map(inbox => inbox.id).join(':'),
      sidebarWhatsappWebAttentionInboxes.value.map(inbox => inbox.id).join(':'),
      sidebarTelegramPersonalHealthyInboxes.value
        .map(inbox => inbox.id)
        .join(':'),
      sidebarTelegramPersonalAttentionInboxes.value
        .map(inbox => inbox.id)
        .join(':'),
    ].join('|'),
  () => {
    syncSidebarRuntimePolling();
  }
);

const loadSidebarCrmPipelines = () => {
  if (!hasCrmDeals.value) {
    return Promise.resolve();
  }

  return crmReferencesStore.loadPipelines();
};

watch(hasCrmDeals, enabled => {
  if (enabled && !crmReferencesStore.pipelines.length) {
    loadSidebarCrmPipelines();
  }
});

onMounted(async () => {
  await Promise.allSettled([
    store.dispatch('labels/get'),
    store.dispatch('inboxes/get'),
    store.dispatch('notifications/unReadCount'),
    ...([
      'communication_threads_dashboard',
      'communication_thread_conversation',
    ].includes(route.name)
      ? []
      : [store.dispatch('fetchSidebarUnreadCounts')]),
    store.dispatch('teams/get'),
    store.dispatch('attributes/get'),
    store.dispatch('customViews/get', 'conversation'),
    store.dispatch('customViews/get', 'contact'),
    loadSidebarCrmPipelines(),
  ]);

  syncSidebarRuntimePolling();
});

onBeforeUnmount(() => {
  stopSidebarRuntimePolling();
});

const closeMobileSidebar = () => {
  if (!props.isMobileSidebarOpen) return;
  emit('closeMobileSidebar');
};

const onComposeOpen = toggleFn => {
  toggleFn();
  emitter.emit(BUS_EVENTS.NEW_CONVERSATION_MODAL, true);
};

const openComposeConversation = () => {
  onComposeOpen(() => composeConversationRef.value?.toggle?.());
};

const onComposeClose = () => {
  emitter.emit(BUS_EVENTS.NEW_CONVERSATION_MODAL, false);
};

const companiesRoute = computed(() =>
  accountScopedRoute(
    'companies_dashboard_index',
    {},
    { page: 1, search: undefined }
  )
);

const buildCompaniesMenuItem = () => ({
  name: 'Companies',
  label: t('SIDEBAR.COMPANIES'),
  icon: 'i-lucide-building-2',
  to: companiesRoute.value,
  activeOn: COMPANY_ACTIVE_ROUTE_NAMES,
});

const newReportRoutes = () => [
  {
    name: 'Reports Agent',
    label: t('SIDEBAR.REPORTS_AGENT'),
    to: accountScopedRoute('agent_reports_index'),
    activeOn: ['agent_reports_show'],
  },
  {
    name: 'Reports Label',
    label: t('SIDEBAR.REPORTS_LABEL'),
    to: accountScopedRoute('label_reports_index'),
  },
  {
    name: 'Reports Inbox',
    label: t('SIDEBAR.REPORTS_INBOX'),
    to: accountScopedRoute('inbox_reports_index'),
    activeOn: ['inbox_reports_show'],
  },
  {
    name: 'Reports Team',
    label: t('SIDEBAR.REPORTS_TEAM'),
    to: accountScopedRoute('team_reports_index'),
    activeOn: ['team_reports_show'],
  },
];

const reportRoutes = computed(() => newReportRoutes());

const settingsInboxRouteNames = [
  'settings_inbox_list',
  'settings_inbox_new',
  'settings_inboxes_page_channel',
  'settings_inboxes_add_agents',
  'settings_inbox_finish',
  'settings_inbox_show',
];

const contactTagSettingsRouteNames = [
  'contact_tags_settings_index',
  'labels_wrapper',
  'labels_list',
];

const labelSidebarActionItems = computed(() => [
  {
    title: t('LABEL_MGMT.HEADER_BTN_TXT'),
    icon: 'i-lucide-plus',
    handler: openCreateLabelPopup,
  },
]);

const conversationSidebarActionItems = computed(() => [
  {
    key: 'compose-conversation',
    label: t('CONTACT_PANEL.NEW_MESSAGE'),
    icon: 'i-lucide-plus',
    handler: openComposeConversation,
  },
]);

const activeOnForEmployeeTab = routeName =>
  employeeSettingsTabs.find(tab => tab.routeName === routeName)?.activeOn || [
    routeName,
  ];

const buildUngroupedMyCompanySettingsMenuItems = () => [
  {
    name: 'Workspace',
    visibilityKey: 'MyCompany:Workspace',
    label: t('SIDEBAR.ACCOUNT_SETTINGS'),
    icon: 'i-lucide-building-2',
    activeOn: WORKSPACE_SETTINGS_ACTIVE_ROUTE_NAMES,
    to: accountScopedRoute('general_settings_index'),
  },
  {
    name: 'Visibility',
    label: t('SIDEBAR.VISIBILITY'),
    icon: 'i-lucide-eye',
    activeOn: ['workspace_sidebar_visibility_settings_index'],
    to: accountScopedRoute('workspace_sidebar_visibility_settings_index'),
  },
  {
    name: 'Conversation Settings',
    label: t('SIDEBAR.CONVERSATION_SETTINGS'),
    icon: 'i-lucide-messages-square',
    activeOn: ['workspace_conversation_settings_index'],
    to: accountScopedRoute('workspace_conversation_settings_index'),
  },
  {
    name: 'Conversation Closure',
    visibilityKey: 'MyCompany:ConversationClosure',
    label: t('CONVERSATION_WORKFLOW.TABS.CLOSURE'),
    icon: 'i-lucide-circle-check-big',
    activeOn: ['workspace_conversation_workflow_settings_index'],
    to: accountScopedRoute('workspace_conversation_workflow_settings_index'),
  },
  ...(hasSLA.value
    ? [
        {
          name: 'SLA',
          visibilityKey: 'MyCompany:SLA',
          label: t('CONVERSATION_WORKFLOW.TABS.SLA'),
          icon: 'i-lucide-timer',
          activeOn: ['workspace_sla_settings_index'],
          to: accountScopedRoute('workspace_sla_settings_index'),
        },
      ]
    : []),
  ...(hasLegacyCustomAttributes.value || hasCrmDeals.value || hasCrmTasks.value
    ? [
        {
          name: 'Additional Fields',
          visibilityKey: 'MyCompany:AdditionalFields',
          label: t('ATTRIBUTES_MGMT.HEADER'),
          icon: 'i-lucide-list-plus',
          permissions: [
            'administrator',
            'crm_settings_view',
            'crm_settings_manage',
          ],
          activeOn: ['workspace_additional_fields_settings_index'],
          to: accountScopedRoute('workspace_additional_fields_settings_index'),
        },
      ]
    : []),
  {
    name: 'Lead Forms',
    visibilityKey: 'MyCompany:LeadForms',
    label: t('SIDEBAR.LEAD_FORMS'),
    icon: 'i-lucide-inbox',
    activeOn: ['lead_forms_index'],
    to: accountScopedRoute('lead_forms_index'),
  },
  ...(hasInboxManagement.value
    ? [
        {
          name: 'Channels',
          visibilityKey: 'MyCompany:Channels',
          label: t('SIDEBAR.CHANNELS'),
          icon: 'i-lucide-mailbox',
          activeOn: settingsInboxRouteNames,
          to: accountScopedRoute('settings_inbox_list'),
        },
      ]
    : []),
  {
    name: 'Tags',
    visibilityKey: 'MyCompany:Tags',
    label: t('SIDEBAR.LABELS'),
    icon: 'i-lucide-tag',
    activeOn: contactTagSettingsRouteNames,
    to: accountScopedRoute('labels_list'),
  },
  {
    name: 'Employees',
    visibilityKey: 'MyCompany:Employees',
    label: t('EMPLOYEE_SETTINGS.TABS.EMPLOYEES'),
    icon: 'i-lucide-user-round',
    activeOn: activeOnForEmployeeTab('agent_list'),
    to: accountScopedRoute('agent_list'),
  },
  {
    name: 'Teams',
    visibilityKey: 'MyCompany:Teams',
    label: t('EMPLOYEE_SETTINGS.TABS.TEAM'),
    icon: 'i-lucide-users-round',
    activeOn: activeOnForEmployeeTab('settings_teams_list'),
    to: accountScopedRoute('settings_teams_list'),
  },
  {
    name: 'Roles',
    visibilityKey: 'MyCompany:Roles',
    label: t('EMPLOYEE_SETTINGS.TABS.ROLES'),
    icon: 'i-lucide-shield-user',
    activeOn: activeOnForEmployeeTab('custom_roles_list'),
    to: accountScopedRoute('custom_roles_list'),
  },
  ...(hasAssignmentPolicies.value
    ? [
        {
          name: 'Policies',
          visibilityKey: 'MyCompany:Policies',
          label: t('EMPLOYEE_SETTINGS.TABS.ASSIGNMENT'),
          icon: 'i-lucide-shield-check',
          activeOn: activeOnForEmployeeTab('assignment_policy_index'),
          to: accountScopedRoute('assignment_policy_index'),
        },
      ]
    : []),
  ...(hasAuditLogs.value
    ? [
        {
          name: 'Audit Logs',
          visibilityKey: 'MyCompany:AuditLogs',
          label: t('SIDEBAR.AUDIT_LOGS'),
          icon: 'i-lucide-scroll-text',
          activeOn: ['auditlogs_list'],
          to: accountScopedRoute('auditlogs_list'),
        },
      ]
    : []),
];

const settingsSection = (name, labelKey) => ({
  type: 'section',
  name: `Settings Section ${name}`,
  // eslint-disable-next-line @intlify/vue-i18n/no-dynamic-keys -- fixed settings section whitelist
  label: t(labelKey),
});

const keepPopulatedSettingsSections = items => {
  const populatedItems = [];
  let pendingSection = null;

  items.forEach(item => {
    if (item.type === 'section') {
      pendingSection = item;
      return;
    }

    if (pendingSection) {
      populatedItems.push(pendingSection);
      pendingSection = null;
    }
    populatedItems.push(item);
  });

  return populatedItems;
};

const buildMyCompanySettingsMenuItems = () => {
  const ungroupedItems = buildUngroupedMyCompanySettingsMenuItems();
  const itemByName = name => ungroupedItems.find(item => item.name === name);
  const administratorItems = hasSettingsAccess.value
    ? {
        automation: hasAutomationRules.value
          ? {
              name: 'Settings Automation',
              visibilityKey: 'Settings:Automation',
              label: t('SIDEBAR.AUTOMATION_RULES'),
              icon: 'i-lucide-repeat',
              activeOn: ['automation_list'],
              to: accountScopedRoute('automation_list'),
            }
          : null,
        quickReplies: {
          name: 'Settings Quick Replies',
          visibilityKey: 'Settings:QuickReplies',
          label: t('SIDEBAR.CANNED_RESPONSES'),
          icon: 'i-lucide-message-square-text',
          activeOn: ['outbound_templates_index'],
          to: accountScopedRoute('outbound_templates_index'),
        },
        whatsAppTemplates: {
          name: 'Settings WhatsApp Templates',
          visibilityKey: 'Settings:WhatsAppTemplates',
          label: t('SIDEBAR.WHATSAPP_TEMPLATES'),
          icon: 'i-lucide-message-circle-code',
          activeOn: ['outbound_whatsapp_templates_index'],
          to: accountScopedRoute('outbound_whatsapp_templates_index'),
        },
        agentBots: {
          name: 'Settings Agent Bots',
          visibilityKey: 'Settings:AgentBots',
          label: t('SIDEBAR.AGENT_BOTS'),
          icon: 'i-lucide-webhook',
          to: accountScopedRoute('agent_bots'),
        },
        macros: {
          name: 'Settings Macros',
          visibilityKey: 'Settings:Macros',
          label: t('SIDEBAR.MACROS'),
          icon: 'i-lucide-toy-brick',
          to: accountScopedRoute('macros_wrapper'),
        },
        integrations: {
          name: 'Settings Integrations',
          visibilityKey: 'Settings:Integrations',
          label: t('SIDEBAR.INTEGRATIONS'),
          icon: 'i-lucide-blocks',
          to: accountScopedRoute('settings_applications'),
        },
        billing: {
          name: 'Settings Billing',
          visibilityKey: 'Settings:Billing',
          label: t('SIDEBAR.BILLING'),
          icon: 'i-lucide-credit-card',
          to: accountScopedRoute('billing_settings_index'),
        },
      }
    : {};

  return [
    settingsSection('Company', 'SIDEBAR.SETTINGS_SECTIONS.COMPANY'),
    itemByName('Workspace'),
    itemByName('Visibility'),
    administratorItems.billing,
    settingsSection('Conversations', 'SIDEBAR.SETTINGS_SECTIONS.CONVERSATIONS'),
    itemByName('Conversation Settings'),
    {
      name: 'Conversation Visibility',
      label: t('CONVERSATION_WORKFLOW.TABS.VISIBILITY'),
      icon: 'i-lucide-panel-left',
      activeOn: ['workspace_conversation_visibility_settings_index'],
      to: accountScopedRoute(
        'workspace_conversation_visibility_settings_index'
      ),
    },
    itemByName('Conversation Closure'),
    itemByName('SLA'),
    administratorItems.quickReplies,
    administratorItems.macros,
    settingsSection('Channels', 'SIDEBAR.SETTINGS_SECTIONS.CHANNELS'),
    itemByName('Channels'),
    administratorItems.whatsAppTemplates,
    itemByName('Lead Forms'),
    administratorItems.integrations,
    administratorItems.agentBots,
    settingsSection('Automation', 'SIDEBAR.SETTINGS_SECTIONS.AUTOMATION'),
    administratorItems.automation,
    settingsSection('Team', 'SIDEBAR.SETTINGS_SECTIONS.TEAM'),
    itemByName('Employees'),
    itemByName('Teams'),
    itemByName('Roles'),
    itemByName('Policies'),
    itemByName('Audit Logs'),
    settingsSection('Data', 'SIDEBAR.SETTINGS_SECTIONS.DATA'),
    itemByName('Additional Fields'),
    itemByName('Tags'),
  ].filter(Boolean);
};

const myCompanySettingsMenuItems = computed(() => {
  const items = buildMyCompanySettingsMenuItems();
  const accessibleItems = hasSettingsAccess.value
    ? items
    : items.filter(
        item =>
          item.type === 'section' ||
          (item.permissions?.length && checkPermissions(item.permissions))
      );
  return keepPopulatedSettingsSections(
    filterSidebarMenuItems(
      accessibleItems,
      effectiveSidebarVisibilitySettings.value
    )
  );
});

const menuItems = computed(() => {
  return filterSidebarMenuItems(
    [
      {
        name: 'Inbox',
        label: t('SIDEBAR.INBOX'),
        icon: 'i-lucide-bell',
        to: accountScopedRoute('inbox_view'),
        activeOn: ['inbox_view', 'inbox_view_conversation'],
        getterKeys: {
          count: 'notifications/getUnreadCount',
        },
      },
      {
        name: 'Conversation',
        label: t('SIDEBAR.CONVERSATIONS'),
        icon: 'i-lucide-message-circle',
        defaultChildName: 'Open',
        to: accountScopedRoute(
          hasCommunicationThreads.value
            ? 'communication_threads_dashboard'
            : 'home',
          {},
          conversationNavigationQuery({ status: 'open' })
        ),
        actionItems: conversationSidebarActionItems.value,
        children: [
          ...conversationAssigneeStatusItems.value,
          ...crmPipelineSidebarItems.value,
          ...appointmentStatusSidebarItems.value,
          {
            name: 'Folders',
            visibilityKey: 'Conversation:Folders',
            label: t('SIDEBAR.CUSTOM_VIEWS_FOLDER'),
            icon: 'i-lucide-folder',
            activeOn: ['conversations_through_folders'],
            children: conversationCustomViews.value.map(view => ({
              name: `${view.name}-${view.id}`,
              label: view.name,
              to: withConversationStatus('folder_conversations', {
                id: view.id,
              }),
            })),
          },
          {
            name: 'Teams',
            visibilityKey: 'Conversation:Teams',
            label: t('SIDEBAR.TEAMS'),
            icon: 'i-lucide-users',
            active: hasRouteTeamScopeAny(),
            to: withTeamScopeToggle(),
            suppressExactPathActive: true,
            activeOn: [],
            suppressHeaderActiveWhenChildActive: true,
            children: teams.value.map(team => ({
              name: `${team.name}-${team.id}`,
              label: team.name,

              to: withConversationStatus(
                'team_conversations',
                {
                  teamId: team.id,
                },
                {
                  labels_scope: undefined,
                  team_scope: undefined,
                }
              ),
            })),
          },
          ...(labels.value.length
            ? [
                {
                  name: 'Labels',
                  visibilityKey: 'Conversation:Labels',
                  label: t('SIDEBAR.LABELS'),
                  icon: 'i-lucide-tag',
                  actionItems: labelSidebarActionItems.value,
                  active: hasRouteLabelsScopeAny(),
                  to: withLabelsScopeToggle(),
                  suppressExactPathActive: true,
                  activeOn: [],
                  suppressHeaderActiveWhenChildActive: true,
                  children: [
                    ...labels.value.map(label => ({
                      name: `${label.title}-${label.id}`,
                      label: labelDisplayTitle(label),

                      compactIconGap: labelMarkerType(label) === 'emoji',
                      iconClass:
                        labelMarkerType(label) === 'emoji' ? '!size-5' : '',
                      icon: h('span', {
                        class:
                          labelMarkerType(label) === 'emoji'
                            ? 'text-xl leading-none'
                            : 'size-3 rounded-sm',
                        style:
                          labelMarkerType(label) === 'emoji'
                            ? undefined
                            : { backgroundColor: labelMarkerColor(label) },
                        innerText:
                          labelMarkerType(label) === 'emoji'
                            ? labelMarkerEmoji(label)
                            : '',
                      }),
                      to: withConversationStatus(
                        'label_conversations',
                        {
                          label: label.title,
                        },
                        {
                          labels_scope: undefined,
                          team_scope: undefined,
                        }
                      ),
                    })),
                  ],
                },
              ]
            : []),
        ],
      },
      ...(checkPermissions(['administrator'])
        ? [
            {
              name: 'Mass broadcasts',
              visibilityKey: 'Campaigns:MassBroadcasts',
              label: t('SIDEBAR.MASS_BROADCASTS'),
              icon: 'i-lucide-megaphone',
              activeOn: ['outbound_broadcasts_index'],
              to: accountScopedRoute('outbound_broadcasts_index'),
            },
          ]
        : []),
      {
        name: 'Captain',
        icon: 'i-woot-captain',
        label: 'AI',
        defaultChildName: 'Profile',
        activeOn: ['captain_assistants_create_index'],
        children: [
          {
            name: 'Profile',
            visibilityKey: 'Captain:Settings',
            label: t('PROFILE_SETTINGS.FORM.PROFILE_SECTION.TITLE'),
            activeOn: ['captain_assistants_settings_index'],
            to: accountScopedRoute('captain_assistants_index', {
              navigationPath: 'captain_assistants_settings_index',
            }),
          },
          {
            name: 'Prompts',
            visibilityKey: 'Captain:Prompts',
            label: t('SIDEBAR.CAPTAIN_PROMPTS'),
            activeOn: [
              'captain_assistants_prompts_index',
              'captain_assistants_scenarios_index',
              'captain_assistants_restrictions_index',
              'captain_assistants_guardrails_index',
              'captain_assistants_guidelines_index',
            ],
            to: accountScopedRoute('captain_assistants_index', {
              navigationPath: 'captain_assistants_prompts_index',
            }),
          },
          {
            name: 'Sandbox',
            visibilityKey: 'Captain:Playground',
            label: t('SIDEBAR.CAPTAIN_PLAYGROUND'),
            activeOn: ['captain_assistants_playground_index'],
            to: accountScopedRoute('captain_assistants_index', {
              navigationPath: 'captain_assistants_playground_index',
            }),
          },
          {
            name: 'Follow-up scenarios',
            visibilityKey: 'Captain:FollowUps',
            label: t('SIDEBAR.CAPTAIN_FOLLOW_UPS'),
            activeOn: ['captain_assistants_follow_ups_index'],
            to: accountScopedRoute('captain_assistants_index', {
              navigationPath: 'captain_assistants_follow_ups_index',
            }),
          },
          {
            name: 'Tools',
            visibilityKey: 'Captain:Tools',
            label: t('SIDEBAR.CAPTAIN_TOOLS'),
            activeOn: ['captain_tools_index'],
            to: accountScopedRoute('captain_assistants_index', {
              navigationPath: 'captain_tools_index',
            }),
          },
          {
            name: 'Observability',
            visibilityKey: 'Captain:Observability',
            label: t('SIDEBAR.CAPTAIN_OBSERVABILITY'),
            activeOn: ['captain_observability_index'],
            to: accountScopedRoute('captain_observability_index'),
          },
          {
            name: 'Knowledge Base',
            visibilityKey: 'Captain:FAQs',
            label: t('SIDEBAR.CAPTAIN_RESPONSES'),
            activeOn: [
              'captain_assistants_responses_index',
              'captain_assistants_responses_pending',
              'captain_assistants_documents_index',
            ],
            to: accountScopedRoute('captain_assistants_index', {
              navigationPath: 'captain_assistants_responses_index',
            }),
          },
          ...(checkPermissions(['administrator'])
            ? [
                {
                  name: 'AI expenses',
                  visibilityKey: 'Captain:Usage',
                  label: t('SIDEBAR.CAPTAIN_USAGE'),
                  activeOn: ['captain_usage_index'],
                  to: accountScopedRoute('captain_usage_index'),
                },
              ]
            : []),
        ],
      },
      {
        name: 'Contacts',
        label: t('SIDEBAR.CONTACTS'),
        icon: 'i-lucide-square-user-round',
        defaultChildName: 'All Contacts',
        children: [
          {
            name: 'All Contacts',
            visibilityKey: 'Contacts:All',
            label: t('SIDEBAR.ALL_CONTACTS'),
            to: accountScopedRoute(
              'contacts_dashboard_index',
              {},
              { page: 1, search: undefined }
            ),
            activeOn: ['contacts_dashboard_index', 'contacts_edit'],
          },
          {
            name: 'Active',
            visibilityKey: 'Contacts:Active',
            label: t('SIDEBAR.ACTIVE'),
            to: accountScopedRoute('contacts_dashboard_active'),
            activeOn: ['contacts_dashboard_active'],
          },
          {
            name: 'Segments',
            visibilityKey: 'Contacts:Segments',
            icon: 'i-lucide-group',
            label: t('SIDEBAR.CUSTOM_VIEWS_SEGMENTS'),
            children: contactCustomViews.value.map(view => ({
              name: `${view.name}-${view.id}`,
              label: view.name,
              to: accountScopedRoute(
                'contacts_dashboard_segments_index',
                { segmentId: view.id },
                { page: 1 }
              ),
              activeOn: [
                'contacts_dashboard_segments_index',
                'contacts_edit_segment',
              ],
            })),
          },
          ...(labels.value.length
            ? [
                {
                  name: 'Tagged With',
                  visibilityKey: 'Contacts:Tagged',
                  icon: 'i-lucide-tag',
                  label: t('SIDEBAR.TAGGED_WITH'),
                  actionItems: labelSidebarActionItems.value,
                  children: labels.value.map(label => ({
                    name: `${label.title}-${label.id}`,
                    label: labelDisplayTitle(label),
                    compactIconGap: labelMarkerType(label) === 'emoji',
                    iconClass:
                      labelMarkerType(label) === 'emoji' ? '!size-5' : '',
                    icon: h('span', {
                      class:
                        labelMarkerType(label) === 'emoji'
                          ? 'text-xl leading-none'
                          : 'size-3 rounded-sm',
                      style:
                        labelMarkerType(label) === 'emoji'
                          ? undefined
                          : { backgroundColor: labelMarkerColor(label) },
                      innerText:
                        labelMarkerType(label) === 'emoji'
                          ? labelMarkerEmoji(label)
                          : '',
                    }),
                    to: accountScopedRoute(
                      'contacts_dashboard_labels_index',
                      { label: label.title },
                      { page: 1, search: undefined }
                    ),
                    activeOn: [
                      'contacts_dashboard_labels_index',
                      'contacts_edit_label',
                    ],
                  })),
                },
              ]
            : []),
        ],
      },
      ...(hasCompanies.value ? [buildCompaniesMenuItem()] : []),
      {
        name: 'CRM',
        label: t('SIDEBAR.PIPELINES'),
        icon: 'i-lucide-briefcase-business',
        to: accountScopedRoute('crm_deals_index'),
        activeOn: ['crm_deals_index', 'crm_settings_index'],
      },
      {
        name: 'CRM Tasks',
        label: t('SIDEBAR.CRM_TASKS'),
        icon: 'i-lucide-list-todo',
        to: accountScopedRoute('crm_tasks_index'),
        activeOn: ['crm_tasks_index', 'crm_task_settings_index'],
      },
      {
        name: 'Scheduling',
        label: t('SIDEBAR.SCHEDULING'),
        icon: 'i-lucide-calendar-clock',
        defaultChildName: 'Scheduling Calendar',
        children: [
          {
            name: 'Scheduling Calendar',
            visibilityKey: 'Scheduling:Calendar',
            label: t('SIDEBAR.SCHEDULING_CALENDAR'),
            to: accountScopedRoute('scheduling_calendar'),
          },
          ...(hasSettingsAccess.value
            ? [
                {
                  name: 'Scheduling Resources',
                  visibilityKey: 'Scheduling:Resources',
                  label: t('SIDEBAR.SCHEDULING_RESOURCES'),
                  to: accountScopedRoute('scheduling_resources'),
                },
                {
                  name: 'Scheduling Services',
                  visibilityKey: 'Scheduling:Services',
                  label: t('SIDEBAR.SCHEDULING_SERVICES'),
                  to: accountScopedRoute('scheduling_services'),
                },
                {
                  name: 'Scheduling Exceptions',
                  visibilityKey: 'Scheduling:Exceptions',
                  label: t('SIDEBAR.SCHEDULING_EXCEPTIONS'),
                  to: accountScopedRoute('scheduling_exceptions'),
                },
                ...(hasSchedulingSettings.value
                  ? [
                      {
                        name: 'Scheduling Settings',
                        visibilityKey: 'Scheduling:Settings',
                        label: t('SIDEBAR.SETTINGS'),
                        activeOn: ['scheduling_settings_index'],
                        to: accountScopedRoute('scheduling_settings_index'),
                      },
                    ]
                  : []),
              ]
            : []),
        ],
      },
      {
        name: 'Reports',
        label: t('SIDEBAR.REPORTS'),
        icon: 'i-lucide-chart-spline',
        defaultChildName: 'Report Overview',
        children: [
          {
            name: 'Report Overview',
            visibilityKey: 'Reports:Overview',
            label: t('SIDEBAR.REPORTS_OVERVIEW'),
            to: accountScopedRoute('account_overview_reports'),
          },
          {
            name: 'Report Conversation',
            visibilityKey: 'Reports:Conversation',
            label: t('SIDEBAR.REPORTS_CONVERSATION'),
            to: accountScopedRoute('conversation_reports'),
          },
          ...(hasCrmDeals.value
            ? [
                {
                  name: 'Reports Deals',
                  visibilityKey: 'Reports:Deals',
                  label: t('SIDEBAR.REPORTS_DEALS'),
                  to: accountScopedRoute('deal_reports'),
                },
              ]
            : []),
          ...reportRoutes.value.map(reportRoute => ({
            ...reportRoute,
            visibilityKey: {
              'Reports Agent': 'Reports:Agent',
              'Reports Label': 'Reports:Label',
              'Reports Inbox': 'Reports:Inbox',
              'Reports Team': 'Reports:Team',
            }[reportRoute.name],
          })),
          {
            name: 'Reports CSAT',
            visibilityKey: 'Reports:CSAT',
            label: t('SIDEBAR.CSAT'),
            to: accountScopedRoute('csat_reports'),
          },
          {
            name: 'Reports SLA',
            visibilityKey: 'Reports:SLA',
            label: t('SIDEBAR.REPORTS_SLA'),
            to: accountScopedRoute('sla_reports'),
          },
          {
            name: 'Reports Bot',
            visibilityKey: 'Reports:Bot',
            label: t('SIDEBAR.REPORTS_BOT'),
            to: accountScopedRoute('bot_reports'),
          },
        ],
      },
      {
        name: 'Portals',
        label: t('SIDEBAR.HELP_CENTER.TITLE'),
        icon: 'i-lucide-library-big',
        defaultChildName: 'Articles',
        children: [
          {
            name: 'Articles',
            visibilityKey: 'Portals:Articles',
            label: t('SIDEBAR.HELP_CENTER.ARTICLES'),
            activeOn: [
              'portals_articles_index',
              'portals_articles_new',
              'portals_articles_edit',
            ],
            to: accountScopedRoute('portals_index', {
              navigationPath: 'portals_articles_index',
            }),
          },
          {
            name: 'Categories',
            visibilityKey: 'Portals:Categories',
            label: t('SIDEBAR.HELP_CENTER.CATEGORIES'),
            activeOn: [
              'portals_categories_index',
              'portals_categories_articles_index',
              'portals_categories_articles_edit',
            ],
            to: accountScopedRoute('portals_index', {
              navigationPath: 'portals_categories_index',
            }),
          },
          {
            name: 'Locales',
            visibilityKey: 'Portals:Locales',
            label: t('SIDEBAR.HELP_CENTER.LOCALES'),
            activeOn: ['portals_locales_index'],
            to: accountScopedRoute('portals_index', {
              navigationPath: 'portals_locales_index',
            }),
          },
          {
            name: 'Settings',
            visibilityKey: 'Portals:Settings',
            label: t('SIDEBAR.HELP_CENTER.SETTINGS'),
            activeOn: ['portals_settings_index'],
            to: accountScopedRoute('portals_index', {
              navigationPath: 'portals_settings_index',
            }),
          },
        ],
      },
      ...(hasSettingsAccess.value || hasCrmSettingsAccess.value
        ? [
            {
              name: 'Settings',
              label: t('SIDEBAR.ADDITIONAL'),
              icon: 'i-lucide-settings-2',
              defaultChildName: 'Workspace',
              children: myCompanySettingsMenuItems.value,
            },
          ]
        : []),
    ],
    effectiveSidebarVisibilitySettings.value
  );
});

const notificationMenuItem = computed(() =>
  menuItems.value.find(item => item.name === 'Inbox')
);

const primaryMenuItems = computed(() =>
  isEffectivelyCollapsed.value
    ? menuItems.value.filter(item => item.name !== 'Inbox')
    : menuItems.value
);

const resolvePath = to => {
  if (to) return router.resolve(to)?.path || '/';
  return '/';
};

const navigableChildrenFor = item => {
  return (
    item.children?.flatMap(child => {
      if (child.type === 'tabs') return child.items || [];
      if (!child.children) return child;
      return child.to ? [child, ...child.children] : child.children;
    }) || []
  );
};

const queryMatches = child => {
  const childQuery = child?.to?.query || {};
  const assigneeItemType = child?.name?.startsWith('Assignee:')
    ? child.name.split(':')[1]
    : null;
  const routeAssigneeType =
    route.query.assignee_type ?? route.query.assigneeType ?? 'me';

  if (
    assigneeItemType &&
    !Object.prototype.hasOwnProperty.call(childQuery, 'assignee_type') &&
    String(routeAssigneeType) !== String(assigneeItemType)
  ) {
    return false;
  }

  return Object.entries(childQuery).every(([key, value]) => {
    let routeValue = route.query[key] ?? '';

    if (key === 'status') {
      routeValue = route.query[key] ?? 'open';
    }

    if (key === 'assignee_type') {
      routeValue =
        route.query.assignee_type ?? route.query.assigneeType ?? 'me';
    }

    return String(routeValue) === String(value);
  });
};

const paramsMatch = child => {
  const childParams = child?.to?.params || {};
  const routeParams = route.params || {};
  const inboxIdAliases = {
    inbox_id: 'inboxId',
    inboxId: 'inbox_id',
  };

  return Object.keys(childParams).every(key => {
    const childParam = String(childParams[key]);
    const routeParam = String(routeParams[key] || '');
    const routeParamAlias = routeParams[inboxIdAliases[key]] || '';

    if (key === 'navigationPath') {
      return (
        childParam === String(route.name || '') || childParam === routeParam
      );
    }

    return (
      childParam === routeParam ||
      (routeParamAlias && childParam === String(routeParamAlias))
    );
  });
};

const matchesChildRoute = child => {
  if (!child?.to) {
    return false;
  }

  if (route.path === resolvePath(child.to) && queryMatches(child)) {
    return !child.suppressExactPathActive;
  }

  if (child.activeOn?.includes(route.name)) {
    return paramsMatch(child) && queryMatches(child);
  }

  if (Array.isArray(child.activeOn) && child.activeOn.length > 0) {
    return false;
  }

  return route.path.startsWith(resolvePath(child.to)) && queryMatches(child);
};

const activeChildNamesFor = item =>
  navigableChildrenFor(item)
    .filter(matchesChildRoute)
    .map(child => child.name);

const hasSecondaryColumn = item => !!item?.children?.length;

const matchesMenuItemRoute = item => {
  if (!item?.to) return false;
  if (route.path === resolvePath(item.to)) return true;
  return item.activeOn?.includes(route.name);
};

const selectedDesktopSidebarItem = computed(() => {
  const selectedItem = menuItems.value.find(
    item => item.name === expandedItem.value && hasSecondaryColumn(item)
  );

  if (selectedItem) return selectedItem;

  return (
    menuItems.value.find(
      item =>
        hasSecondaryColumn(item) &&
        (activeChildNamesFor(item).length > 0 || matchesMenuItemRoute(item))
    ) || null
  );
});

const selectedDesktopSidebarActiveChildNames = computed(() => {
  if (!selectedDesktopSidebarItem.value) return [];
  return activeChildNamesFor(selectedDesktopSidebarItem.value);
});

const showDesktopSecondaryColumn = computed(
  () => !isMobile.value && !!selectedDesktopSidebarItem.value
);

const desktopSidebarWidth = computed(() => {
  if (isMobile.value) return undefined;

  return (
    DESKTOP_RAIL_WIDTH +
    (showDesktopSecondaryColumn.value ? DESKTOP_SECONDARY_COLUMN_WIDTH : 0)
  );
});
</script>

<template>
  <aside
    v-on-click-outside="[
      closeMobileSidebar,
      { ignore: ['#mobile-sidebar-launcher'] },
    ]"
    class="bg-n-background flex text-sm fixed top-0 ltr:left-0 rtl:right-0 h-full z-40 w-[200px] md:w-auto md:relative md:flex-shrink-0 md:ltr:translate-x-0 md:rtl:translate-x-0 ltr:border-r rtl:border-l border-n-weak transition-transform duration-200 ease-out"
    :class="[
      {
        'shadow-lg md:shadow-none': isMobileSidebarOpen,
        'ltr:-translate-x-full rtl:translate-x-full': !isMobileSidebarOpen,
      },
    ]"
    :style="isMobile ? undefined : { width: `${desktopSidebarWidth}px` }"
  >
    <div
      class="flex h-full min-w-0 flex-col bg-n-background pb-px"
      :class="[
        isEffectivelyCollapsed
          ? 'w-11 flex-shrink-0 ltr:border-r rtl:border-l border-n-weak'
          : 'w-full',
      ]"
    >
      <section
        class="grid"
        :class="isEffectivelyCollapsed ? 'mt-2 mb-4 gap-3' : 'mt-1 mb-3 gap-2'"
      >
        <div
          class="flex gap-2 items-center min-w-0"
          :class="{
            'justify-center px-1': isEffectivelyCollapsed,
            'px-2': !isEffectivelyCollapsed,
          }"
        >
          <template v-if="isEffectivelyCollapsed">
            <SidebarAccountSwitcher
              is-collapsed
              @show-create-account-modal="emit('showCreateAccountModal')"
            />
          </template>
          <template v-else>
            <SidebarAccountSwitcher
              class="flex-grow min-w-0"
              @show-create-account-modal="emit('showCreateAccountModal')"
            />
          </template>
        </div>
        <div
          class="flex gap-2"
          :class="isEffectivelyCollapsed ? 'flex-col items-center' : 'px-2'"
        >
          <RouterLink
            v-if="!isEffectivelyCollapsed"
            :to="{ name: 'search' }"
            class="flex gap-2 items-center px-2 py-1 w-full h-7 rounded-lg outline outline-1 outline-n-weak bg-n-button-color transition-all duration-100 ease-out"
          >
            <span
              class="flex-shrink-0 i-lucide-search size-4 text-n-slate-10"
            />
            <span class="flex-grow text-start text-n-slate-10">
              {{ t('COMBOBOX.SEARCH_PLACEHOLDER') }}
            </span>
            <span
              class="hidden tracking-wide pointer-events-none select-none text-n-slate-10"
            >
              {{ searchShortcut }}
            </span>
          </RouterLink>
          <RouterLink
            v-else
            :to="{ name: 'search' }"
            class="inline-flex size-8 items-center justify-center rounded-lg text-n-slate-11 outline outline-1 outline-n-weak bg-n-button-color hover:bg-n-alpha-2 hover:text-n-slate-12"
            :aria-label="t('COMBOBOX.SEARCH_PLACEHOLDER')"
            :title="t('COMBOBOX.SEARCH_PLACEHOLDER')"
          >
            <span class="i-lucide-search size-4.5" />
          </RouterLink>
        </div>
      </section>
      <nav
        class="sidebar-icon-rail-scroll grid overflow-y-auto flex-grow gap-2 pb-5 no-scrollbar min-w-0"
        :class="isEffectivelyCollapsed ? 'px-1' : 'px-2'"
      >
        <ul
          class="flex flex-col gap-1 m-0 list-none min-w-0"
          :class="{ 'items-center': isEffectivelyCollapsed }"
        >
          <SidebarGroup
            v-for="item in primaryMenuItems"
            :key="item.name"
            v-bind="item"
            :show-collapsed-popover="false"
          />
        </ul>
      </nav>
      <section
        class="flex relative flex-col flex-shrink-0 gap-1 justify-between items-center"
      >
        <div
          class="pointer-events-none absolute inset-x-0 -top-[1.938rem] h-8 bg-gradient-to-t from-n-background to-transparent"
        />
        <SidebarChangelogCard
          v-if="
            isOnChatwootCloud &&
            !isACustomBrandedInstance &&
            !isEffectivelyCollapsed
          "
        />
        <SidebarChangelogButton
          v-if="
            isOnChatwootCloud &&
            !isACustomBrandedInstance &&
            isEffectivelyCollapsed
          "
        />
        <div
          class="px-1 py-1.5 flex-shrink-0 flex w-full z-50 gap-2 items-center border-t border-n-weak shadow-[0px_-2px_4px_0px_rgba(27,28,29,0.02)]"
          :class="
            isEffectivelyCollapsed
              ? 'flex-col justify-center'
              : 'justify-between'
          "
        >
          <SidebarProfileMenu
            :is-collapsed="isEffectivelyCollapsed"
            @open-key-shortcut-modal="emit('openKeyShortcutModal')"
          />
          <ul
            v-if="isEffectivelyCollapsed && notificationMenuItem"
            class="flex m-0 list-none"
            :class="{ 'justify-center': isEffectivelyCollapsed }"
          >
            <SidebarGroup
              v-bind="notificationMenuItem"
              :show-collapsed-popover="false"
            />
          </ul>
        </div>
      </section>
    </div>
    <SidebarSecondaryColumn
      v-if="showDesktopSecondaryColumn"
      v-bind="selectedDesktopSidebarItem"
      :active-child-names="selectedDesktopSidebarActiveChildNames"
    />
    <Teleport to="body">
      <ComposeConversation
        ref="composeConversationRef"
        is-modal
        @close="onComposeClose"
      />
      <woot-modal
        v-model:show="showCreateLabelPopup"
        @close="hideCreateLabelPopup"
      >
        <AddLabelForm @close="hideCreateLabelPopup" />
      </woot-modal>
    </Teleport>
  </aside>
</template>

<style scoped>
.sidebar-icon-rail-scroll {
  -ms-overflow-style: none;
  scrollbar-width: none;
}

.sidebar-icon-rail-scroll::-webkit-scrollbar {
  display: none;
  width: 0;
  height: 0;
}
</style>
