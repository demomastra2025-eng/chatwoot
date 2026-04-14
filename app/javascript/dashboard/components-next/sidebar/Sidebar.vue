<script setup>
import { h, ref, computed, onMounted, onBeforeUnmount, watch } from 'vue';
import { useRoute } from 'vue-router';
import { provideSidebarContext, useSidebarResize } from './provider';
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

import Button from 'dashboard/components-next/button/Button.vue';
import SidebarGroup from './SidebarGroup.vue';
import SidebarProfileMenu from './SidebarProfileMenu.vue';
import SidebarChangelogCard from './SidebarChangelogCard.vue';
import SidebarChangelogButton from './SidebarChangelogButton.vue';
import ChannelLeaf from './ChannelLeaf.vue';
import ChannelStatusIcon from './ChannelStatusIcon.vue';
import SidebarAccountSwitcher from './SidebarAccountSwitcher.vue';
import Logo from 'next/icon/Logo.vue';
import ComposeConversation from 'dashboard/components-next/NewConversation/ComposeConversation.vue';
import { filterSidebarMenuItems } from './sidebarVisibility';
import {
  isInboxPendingDeletion,
  isWhatsappWebInbox,
  WHATSAPP_WEB_SIDEBAR_STATUS_POLL_INTERVAL,
} from 'dashboard/helper/whatsappWeb';
import {
  isTelegramPersonalInbox,
  TELEGRAM_PERSONAL_SIDEBAR_STATUS_POLL_INTERVAL,
} from 'dashboard/helper/telegramPersonal';

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

const { accountScopedRoute, isOnChatwootCloud } = useAccount();
const route = useRoute();
const { checkPermissions } = usePolicy();
const store = useStore();
const searchShortcut = useKbd([`$mod`, 'k']);
const { t } = useI18n();
const { uiSettings } = useUISettings();

const isACustomBrandedInstance = useMapGetter(
  'globalConfig/isACustomBrandedInstance'
);
const isRTL = useMapGetter('accounts/isRTL');

const { width: windowWidth } = useWindowSize();
const isMobile = computed(() => windowWidth.value < 768);

const accountId = useMapGetter('getCurrentAccountId');
const isFeatureEnabledonAccount = useMapGetter(
  'accounts/isFeatureEnabledonAccount'
);

const hasAdvancedAssignment = computed(() => {
  return isFeatureEnabledonAccount.value(
    accountId.value,
    FEATURE_FLAGS.ADVANCED_ASSIGNMENT
  );
});

const hasCrmRuntime = computed(() => {
  return (
    isFeatureEnabledonAccount.value(accountId.value, FEATURE_FLAGS.CRM_DEALS) ||
    isFeatureEnabledonAccount.value(accountId.value, FEATURE_FLAGS.CRM_TASKS)
  );
});

const hasCrmDealSettings = computed(() => {
  return isFeatureEnabledonAccount.value(
    accountId.value,
    FEATURE_FLAGS.CRM_DEALS
  );
});

const hasCrmTaskSettings = computed(() => {
  return isFeatureEnabledonAccount.value(
    accountId.value,
    FEATURE_FLAGS.CRM_TASKS
  );
});

const hasSchedulingSettings = computed(() => {
  return isFeatureEnabledonAccount.value(
    accountId.value,
    FEATURE_FLAGS.SCHEDULING
  );
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

const hasUnifiedCustomAttributes = computed(() => {
  return (
    hasLegacyCustomAttributes.value ||
    (checkPermissions([
      'administrator',
      'crm_settings_view',
      'crm_settings_manage',
    ]) &&
      hasCrmRuntime.value)
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

const setExpandedItem = name => {
  expandedItem.value = expandedItem.value === name ? null : name;
};

const {
  sidebarWidth,
  isCollapsed,
  setSidebarWidth,
  saveWidth,
  snapToCollapsed,
  snapToExpanded,
  COLLAPSED_THRESHOLD,
} = useSidebarResize();

// On mobile, sidebar is always expanded (flyout mode)
const isEffectivelyCollapsed = computed(
  () => !isMobile.value && isCollapsed.value
);

// Resize handle logic
const isResizing = ref(false);
const startX = ref(0);
const startWidth = ref(0);

provideSidebarContext({
  expandedItem,
  setExpandedItem,
  isCollapsed: isEffectivelyCollapsed,
  sidebarWidth,
  isResizing,
});

// Get clientX from mouse or touch event
const getClientX = event =>
  event.touches ? event.touches[0].clientX : event.clientX;

const onResizeStart = event => {
  isResizing.value = true;
  startX.value = getClientX(event);
  startWidth.value = sidebarWidth.value;
  Object.assign(document.body.style, {
    cursor: 'col-resize',
    userSelect: 'none',
  });
  // Prevent default to avoid scrolling on touch
  event.preventDefault();
};

const onResizeMove = event => {
  if (!isResizing.value) return;

  const delta = isRTL.value
    ? startX.value - getClientX(event)
    : getClientX(event) - startX.value;
  setSidebarWidth(startWidth.value + delta);
};

const onResizeEnd = () => {
  if (!isResizing.value) return;

  isResizing.value = false;
  Object.assign(document.body.style, { cursor: '', userSelect: '' });

  // Snap to collapsed state if below threshold
  if (sidebarWidth.value < COLLAPSED_THRESHOLD) {
    snapToCollapsed();
  } else {
    saveWidth();
  }
};

const onResizeHandleDoubleClick = () => {
  if (isCollapsed.value) snapToExpanded();
  else snapToCollapsed();
};

// Support both mouse and touch events
useEventListener(document, 'mousemove', onResizeMove);
useEventListener(document, 'mouseup', onResizeEnd);
useEventListener(document, 'touchmove', onResizeMove, { passive: false });
useEventListener(document, 'touchend', onResizeEnd);

const inboxes = useMapGetter('inboxes/getInboxes');
const labels = useMapGetter('labels/getLabelsOnSidebar');
const teams = useMapGetter('teams/getMyTeams');
const contactCustomViews = useMapGetter('customViews/getContactCustomViews');
const conversationCustomViews = useMapGetter(
  'customViews/getConversationCustomViews'
);

const sortedInboxes = computed(() =>
  inboxes.value.slice().sort((a, b) => a.name.localeCompare(b.name))
);

const conversationStatuses = ['pending', 'open', 'snoozed', 'resolved'];
const conversationStatusActiveOn = [
  'home',
  'inbox_dashboard',
  'inbox_conversation',
  'conversation_through_inbox',
  'label_conversations',
  'conversations_through_label',
  'team_conversations',
  'conversations_through_team',
  'folder_conversations',
  'conversations_through_folders',
];
const allChannelsActiveOn = [
  'home',
  'inbox_conversation',
  'label_conversations',
  'conversations_through_label',
  'team_conversations',
  'conversations_through_team',
  'folder_conversations',
  'conversations_through_folders',
];
const allLabelsActiveOn = [
  'home',
  'inbox_dashboard',
  'inbox_conversation',
  'conversation_through_inbox',
  'team_conversations',
  'conversations_through_team',
  'folder_conversations',
  'conversations_through_folders',
];

const currentConversationStatus = computed(() => {
  const routeStatus = route.query.status;

  return conversationStatuses.includes(routeStatus) ? routeStatus : 'open';
});

const withConversationStatus = (name, params = {}) =>
  accountScopedRoute(name, params, { status: currentConversationStatus.value });

const whatsappWebInboxes = computed(() => {
  return sortedInboxes.value.filter(
    inbox => isWhatsappWebInbox(inbox) && !isInboxPendingDeletion(inbox)
  );
});

const telegramPersonalInboxes = computed(() => {
  return sortedInboxes.value.filter(inbox => isTelegramPersonalInbox(inbox));
});

const canManageWhatsappWebLifecycle = computed(() => {
  return checkPermissions(['administrator']);
});

let whatsappWebStatusPollingTimer = null;
let telegramPersonalStatusPollingTimer = null;

const stopWhatsappWebStatusPolling = () => {
  if (!whatsappWebStatusPollingTimer) {
    return;
  }

  window.clearInterval(whatsappWebStatusPollingTimer);
  whatsappWebStatusPollingTimer = null;
};

const stopTelegramPersonalStatusPolling = () => {
  if (!telegramPersonalStatusPollingTimer) {
    return;
  }

  window.clearInterval(telegramPersonalStatusPollingTimer);
  telegramPersonalStatusPollingTimer = null;
};

const syncWhatsappWebStatuses = async () => {
  if (
    !canManageWhatsappWebLifecycle.value ||
    (typeof document !== 'undefined' && document.visibilityState !== 'visible')
  ) {
    return;
  }

  if (!whatsappWebInboxes.value.length) {
    return;
  }

  await Promise.allSettled(
    whatsappWebInboxes.value.map(inbox =>
      store.dispatch('inboxes/refreshWhatsappWebQr', {
        inboxId: inbox.id,
        statusOnly: true,
        includeQrCode: false,
      })
    )
  );
};

const syncTelegramPersonalStatuses = async () => {
  if (
    typeof document !== 'undefined' &&
    document.visibilityState !== 'visible'
  ) {
    return;
  }

  if (!telegramPersonalInboxes.value.length) {
    return;
  }

  await Promise.allSettled(
    telegramPersonalInboxes.value.map(inbox =>
      store.dispatch('inboxes/getTelegramPersonalDiagnostics', inbox.id)
    )
  );
};

const startWhatsappWebStatusPolling = () => {
  if (
    whatsappWebStatusPollingTimer ||
    !canManageWhatsappWebLifecycle.value ||
    !whatsappWebInboxes.value.length ||
    (typeof document !== 'undefined' && document.visibilityState !== 'visible')
  ) {
    return;
  }

  whatsappWebStatusPollingTimer = window.setInterval(() => {
    syncWhatsappWebStatuses();
  }, WHATSAPP_WEB_SIDEBAR_STATUS_POLL_INTERVAL);
};

const startTelegramPersonalStatusPolling = () => {
  if (
    telegramPersonalStatusPollingTimer ||
    !telegramPersonalInboxes.value.length ||
    (typeof document !== 'undefined' && document.visibilityState !== 'visible')
  ) {
    return;
  }

  telegramPersonalStatusPollingTimer = window.setInterval(() => {
    syncTelegramPersonalStatuses();
  }, TELEGRAM_PERSONAL_SIDEBAR_STATUS_POLL_INTERVAL);
};

const handleDocumentVisibilityChange = () => {
  if (document.visibilityState === 'visible') {
    syncWhatsappWebStatuses();
    startWhatsappWebStatusPolling();
    syncTelegramPersonalStatuses();
    startTelegramPersonalStatusPolling();
    return;
  }

  stopWhatsappWebStatusPolling();
  stopTelegramPersonalStatusPolling();
};

useEventListener(document, 'visibilitychange', handleDocumentVisibilityChange);

watch(
  () =>
    `${canManageWhatsappWebLifecycle.value}:${whatsappWebInboxes.value
      .map(inbox => inbox.id)
      .join(':')}`,
  inboxIds => {
    if (!inboxIds || !inboxIds.startsWith('true:')) {
      stopWhatsappWebStatusPolling();
      return;
    }

    syncWhatsappWebStatuses();
    startWhatsappWebStatusPolling();
  }
);

watch(
  () => telegramPersonalInboxes.value.map(inbox => inbox.id).join(':'),
  inboxIds => {
    if (!inboxIds) {
      stopTelegramPersonalStatusPolling();
      return;
    }

    syncTelegramPersonalStatuses();
    startTelegramPersonalStatusPolling();
  }
);

onMounted(async () => {
  await Promise.allSettled([
    store.dispatch('labels/get'),
    store.dispatch('inboxes/get'),
    store.dispatch('notifications/unReadCount'),
    store.dispatch('teams/get'),
    store.dispatch('attributes/get'),
    store.dispatch('customViews/get', 'conversation'),
    store.dispatch('customViews/get', 'contact'),
  ]);

  if (canManageWhatsappWebLifecycle.value) {
    await syncWhatsappWebStatuses();
    startWhatsappWebStatusPolling();
  }
  await syncTelegramPersonalStatuses();
  startTelegramPersonalStatusPolling();
});

onBeforeUnmount(() => {
  stopWhatsappWebStatusPolling();
  stopTelegramPersonalStatusPolling();
});

const closeMobileSidebar = () => {
  if (!props.isMobileSidebarOpen) return;
  emit('closeMobileSidebar');
};

const onComposeOpen = toggleFn => {
  toggleFn();
  emitter.emit(BUS_EVENTS.NEW_CONVERSATION_MODAL, true);
};

const onComposeClose = () => {
  emitter.emit(BUS_EVENTS.NEW_CONVERSATION_MODAL, false);
};

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
        to: accountScopedRoute('home', {}, { status: 'open' }),
        children: [
          {
            name: 'Pending',
            visibilityKey: 'Conversation:Pending',
            label: t('SIDEBAR.PENDING_CONVERSATIONS'),
            icon: 'i-woot-captain',
            activeOn: conversationStatusActiveOn,
            to: accountScopedRoute('home', {}, { status: 'pending' }),
          },
          {
            name: 'Open',
            visibilityKey: 'Conversation:Open',
            label: t('SIDEBAR.OPEN_CONVERSATIONS'),
            icon: 'i-lucide-inbox',
            activeOn: conversationStatusActiveOn,
            to: accountScopedRoute('home', {}, { status: 'open' }),
          },
          {
            name: 'Snoozed',
            visibilityKey: 'Conversation:Snoozed',
            icon: 'i-lucide-timer-reset',
            activeOn: conversationStatusActiveOn,
            label: t('SIDEBAR.SNOOZED_CONVERSATIONS'),
            to: accountScopedRoute('home', {}, { status: 'snoozed' }),
          },
          {
            name: 'Resolved',
            visibilityKey: 'Conversation:Resolved',
            icon: 'i-lucide-check-check',
            activeOn: conversationStatusActiveOn,
            label: t('SIDEBAR.RESOLVED_CONVERSATIONS'),
            to: accountScopedRoute('home', {}, { status: 'resolved' }),
          },
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
            name: 'Channels',
            visibilityKey: 'Conversation:Channels',
            label: t('SIDEBAR.CHANNELS'),
            icon: 'i-lucide-mailbox',
            to: withConversationStatus('home'),
            activeOn: allChannelsActiveOn,
            actionLabel: t('SIDEBAR.ALL'),
            children: sortedInboxes.value.map(inbox => ({
              name: `${inbox.name}-${inbox.id}`,
              label: inbox.name,
              icon: h(ChannelStatusIcon, { inbox, class: 'size-[16px]' }),
              to: withConversationStatus('inbox_dashboard', {
                inbox_id: inbox.id,
              }),
              component: leafProps =>
                h(ChannelLeaf, {
                  label: leafProps.label,
                  active: leafProps.active,
                  inbox,
                }),
            })),
          },
          {
            name: 'Teams',
            visibilityKey: 'Conversation:Teams',
            label: t('SIDEBAR.TEAMS'),
            icon: 'i-lucide-users',
            activeOn: ['conversations_through_team'],
            children: teams.value.map(team => ({
              name: `${team.name}-${team.id}`,
              label: team.name,
              to: withConversationStatus('team_conversations', {
                teamId: team.id,
              }),
            })),
          },
          {
            name: 'Labels',
            visibilityKey: 'Conversation:Labels',
            label: t('SIDEBAR.LABELS'),
            icon: 'i-lucide-tag',
            to: withConversationStatus('home'),
            activeOn: allLabelsActiveOn,
            actionLabel: t('SIDEBAR.ALL'),
            children: labels.value.map(label => ({
              name: `${label.title}-${label.id}`,
              label: label.title,
              icon: h('span', {
                class: `size-[8px] rounded-sm`,
                style: { backgroundColor: label.color },
              }),
              to: withConversationStatus('label_conversations', {
                label: label.title,
              }),
            })),
          },
        ],
      },
      {
        name: 'Campaigns',
        label: t('SIDEBAR.CAMPAIGNS'),
        icon: 'i-lucide-megaphone',
        children: [
          ...(checkPermissions(['administrator'])
            ? [
                {
                  name: 'Mass broadcasts',
                  visibilityKey: 'Campaigns:MassBroadcasts',
                  label: t('SIDEBAR.MASS_BROADCASTS'),
                  to: accountScopedRoute('outbound_broadcasts_index'),
                },
              ]
            : []),
          {
            name: 'Personal broadcasts',
            visibilityKey: 'Campaigns:PersonalBroadcasts',
            label: t('SIDEBAR.PERSONAL_BROADCASTS'),
            to: accountScopedRoute('outbound_broadcasts_personal_index'),
          },
          {
            name: 'Touch plans',
            visibilityKey: 'Campaigns:TouchPlans',
            label: t('SIDEBAR.TOUCH_PLANS'),
            to: accountScopedRoute('outbound_touch_plans_index'),
          },
          {
            name: 'Templates',
            visibilityKey: 'Campaigns:Templates',
            label: t('SIDEBAR.TEMPLATES'),
            to: accountScopedRoute('outbound_templates_index'),
          },
        ],
      },
      {
        name: 'Captain',
        icon: 'i-woot-captain',
        label: t('SIDEBAR.CAPTAIN'),
        activeOn: ['captain_assistants_create_index'],
        children: [
          {
            name: 'Settings',
            visibilityKey: 'Captain:Settings',
            label: t('SIDEBAR.CAPTAIN_SETTINGS'),
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
              'captain_assistants_guidelines_index',
            ],
            to: accountScopedRoute('captain_assistants_index', {
              navigationPath: 'captain_assistants_prompts_index',
            }),
          },
          {
            name: 'Channels',
            visibilityKey: 'Captain:Channels',
            label: t('SIDEBAR.CAPTAIN_CHANNELS'),
            activeOn: [
              'captain_assistants_channels_index',
              'captain_assistants_inboxes_index',
            ],
            to: accountScopedRoute('captain_assistants_index', {
              navigationPath: 'captain_assistants_channels_index',
            }),
          },
          {
            name: 'Access',
            visibilityKey: 'Captain:Access',
            label: t('SIDEBAR.CAPTAIN_ACCESS'),
            activeOn: ['captain_assistants_access_index'],
            to: accountScopedRoute('captain_assistants_index', {
              navigationPath: 'captain_assistants_access_index',
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
            name: 'FAQs',
            visibilityKey: 'Captain:FAQs',
            label: t('SIDEBAR.CAPTAIN_RESPONSES'),
            activeOn: [
              'captain_assistants_responses_index',
              'captain_assistants_responses_pending',
            ],
            to: accountScopedRoute('captain_assistants_index', {
              navigationPath: 'captain_assistants_responses_index',
            }),
          },
          {
            name: 'Restrictions',
            visibilityKey: 'Captain:Restrictions',
            label: t('SIDEBAR.CAPTAIN_RESTRICTIONS'),
            activeOn: [
              'captain_assistants_restrictions_index',
              'captain_assistants_guardrails_index',
            ],
            to: accountScopedRoute('captain_assistants_index', {
              navigationPath: 'captain_assistants_restrictions_index',
            }),
          },
          {
            name: 'Documents',
            visibilityKey: 'Captain:Documents',
            label: t('SIDEBAR.CAPTAIN_DOCUMENTS'),
            activeOn: ['captain_assistants_documents_index'],
            to: accountScopedRoute('captain_assistants_index', {
              navigationPath: 'captain_assistants_documents_index',
            }),
          },
          {
            name: 'Playground',
            visibilityKey: 'Captain:Playground',
            label: t('SIDEBAR.CAPTAIN_PLAYGROUND'),
            activeOn: ['captain_assistants_playground_index'],
            to: accountScopedRoute('captain_assistants_index', {
              navigationPath: 'captain_assistants_playground_index',
            }),
          },
        ],
      },
      {
        name: 'Contacts',
        label: t('SIDEBAR.CONTACTS'),
        icon: 'i-lucide-contact',
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
          {
            name: 'Tagged With',
            visibilityKey: 'Contacts:Tagged',
            icon: 'i-lucide-tag',
            label: t('SIDEBAR.TAGGED_WITH'),
            children: labels.value.map(label => ({
              name: `${label.title}-${label.id}`,
              label: label.title,
              icon: h('span', {
                class: `size-[8px] rounded-sm`,
                style: { backgroundColor: label.color },
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
        ],
      },
      ...(hasCompanies.value
        ? [
            {
              name: 'Companies',
              label: t('SIDEBAR.COMPANIES'),
              icon: 'i-lucide-building-2',
              to: accountScopedRoute(
                'companies_dashboard_index',
                {},
                { page: 1, search: undefined }
              ),
              activeOn: ['companies_dashboard_index'],
            },
          ]
        : []),
      {
        name: 'CRM',
        label: t('SIDEBAR.PIPELINES'),
        icon: 'i-lucide-filter',
        to: accountScopedRoute('crm_deals_index'),
      },
      {
        name: 'CRM Tasks',
        label: t('SIDEBAR.CRM_TASKS'),
        icon: 'i-lucide-list-todo',
        to: accountScopedRoute('crm_tasks_index'),
      },
      {
        name: 'Scheduling',
        label: t('SIDEBAR.SCHEDULING'),
        icon: 'i-lucide-calendar-clock',
        children: [
          {
            name: 'Scheduling Calendar',
            visibilityKey: 'Scheduling:Calendar',
            label: t('SIDEBAR.SCHEDULING_CALENDAR'),
            to: accountScopedRoute('scheduling_calendar'),
          },
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
          {
            name: 'Scheduling Kassa',
            visibilityKey: 'Scheduling:Kassa',
            label: t('SIDEBAR.SCHEDULING_KASSA'),
            to: accountScopedRoute('scheduling_kassa'),
          },
        ],
      },
      {
        name: 'Reports',
        label: t('SIDEBAR.REPORTS'),
        icon: 'i-lucide-chart-spline',
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
      {
        name: 'Settings',
        label: t('SIDEBAR.SETTINGS'),
        icon: 'i-lucide-bolt',
        children: [
          {
            name: 'Settings Account Settings',
            visibilityKey: 'Settings:Workspace',
            label: t('SIDEBAR.ACCOUNT_SETTINGS'),
            icon: 'i-lucide-briefcase',
            to: accountScopedRoute('general_settings_index'),
          },
          ...(hasSchedulingSettings.value
            ? [
                {
                  name: 'Settings Scheduling',
                  visibilityKey: 'Settings:Scheduling',
                  label: t('SIDEBAR.SCHEDULING'),
                  icon: 'i-lucide-calendar-clock',
                  activeOn: ['scheduling_settings_index'],
                  to: accountScopedRoute('scheduling_settings_index'),
                },
              ]
            : []),
          {
            name: 'Settings Captain',
            visibilityKey: 'Settings:Captain',
            label: t('SIDEBAR.CAPTAIN_AI'),
            icon: 'i-woot-captain',
            to: accountScopedRoute('captain_settings_index'),
          },
          {
            name: 'Settings Agents',
            visibilityKey: 'Settings:Agents',
            label: t('SIDEBAR.AGENTS'),
            icon: 'i-lucide-square-user',
            to: accountScopedRoute('agent_list'),
          },
          {
            name: 'Settings Inboxes',
            visibilityKey: 'Settings:Inboxes',
            label: t('SIDEBAR.INBOXES'),
            icon: 'i-lucide-inbox',
            activeOn: [
              'settings_inbox_list',
              'settings_inbox_show',
              'settings_inbox_new',
              'settings_inbox_finish',
              'settings_inboxes_page_channel',
              'settings_inboxes_add_agents',
            ],
            to: accountScopedRoute('settings_inbox_list'),
          },
          {
            name: 'Settings Teams',
            visibilityKey: 'Settings:Teams',
            label: t('SIDEBAR.TEAMS'),
            icon: 'i-lucide-users',
            activeOn: [
              'settings_teams_list',
              'settings_teams_new',
              'settings_teams_finish',
              'settings_teams_add_agents',
              'settings_teams_show',
              'settings_teams_edit',
              'settings_teams_edit_members',
              'settings_teams_edit_finish',
            ],
            to: accountScopedRoute('settings_teams_list'),
          },
          ...(hasAdvancedAssignment.value
            ? [
                {
                  name: 'Settings Agent Assignment',
                  visibilityKey: 'Settings:AgentAssignment',
                  label: t('SIDEBAR.AGENT_ASSIGNMENT'),
                  icon: 'i-lucide-user-cog',
                  activeOn: [
                    'assignment_policy_index',
                    'agent_assignment_policy_index',
                    'agent_assignment_policy_create',
                    'agent_assignment_policy_edit',
                    'agent_capacity_policy_index',
                    'agent_capacity_policy_create',
                    'agent_capacity_policy_edit',
                  ],
                  to: accountScopedRoute('assignment_policy_index'),
                },
              ]
            : []),
          ...(hasCrmDealSettings.value
            ? [
                {
                  name: 'Settings CRM',
                  visibilityKey: 'Settings:CRM',
                  label: t('SIDEBAR.CRM'),
                  icon: 'i-lucide-filter',
                  activeOn: ['crm_settings_index'],
                  to: accountScopedRoute('crm_settings_index'),
                },
              ]
            : []),
          ...(hasCrmTaskSettings.value
            ? [
                {
                  name: 'Settings CRM Tasks',
                  visibilityKey: 'Settings:CRMTasks',
                  label: t('SIDEBAR.CRM_TASK_SETTINGS'),
                  icon: 'i-lucide-list-todo',
                  activeOn: ['crm_task_settings_index'],
                  to: accountScopedRoute('crm_task_settings_index'),
                },
              ]
            : []),
          {
            name: 'Settings Labels',
            visibilityKey: 'Settings:Labels',
            label: t('SIDEBAR.LABELS'),
            icon: 'i-lucide-tags',
            to: accountScopedRoute('labels_list'),
          },
          ...(hasUnifiedCustomAttributes.value
            ? [
                {
                  name: 'Settings Custom Attributes',
                  visibilityKey: 'Settings:CustomAttributes',
                  label: t('SIDEBAR.CUSTOM_ATTRIBUTES'),
                  icon: 'i-lucide-code',
                  to: accountScopedRoute('attributes_list'),
                },
              ]
            : []),
          {
            name: 'Settings Automation',
            visibilityKey: 'Settings:Automation',
            label: t('SIDEBAR.AUTOMATION'),
            icon: 'i-lucide-repeat',
            to: accountScopedRoute('automation_list'),
          },
          {
            name: 'Settings Agent Bots',
            visibilityKey: 'Settings:AgentBots',
            label: t('SIDEBAR.AGENT_BOTS'),
            icon: 'i-lucide-bot',
            to: accountScopedRoute('agent_bots'),
          },
          {
            name: 'Settings Macros',
            visibilityKey: 'Settings:Macros',
            label: t('SIDEBAR.MACROS'),
            icon: 'i-lucide-toy-brick',
            to: accountScopedRoute('macros_wrapper'),
          },
          {
            name: 'Settings Integrations',
            visibilityKey: 'Settings:Integrations',
            label: t('SIDEBAR.INTEGRATIONS'),
            icon: 'i-lucide-blocks',
            to: accountScopedRoute('settings_applications'),
          },
          {
            name: 'Settings Audit Logs',
            visibilityKey: 'Settings:AuditLogs',
            label: t('SIDEBAR.AUDIT_LOGS'),
            icon: 'i-lucide-briefcase',
            to: accountScopedRoute('auditlogs_list'),
          },
          {
            name: 'Settings Custom Roles',
            visibilityKey: 'Settings:CustomRoles',
            label: t('SIDEBAR.CUSTOM_ROLES'),
            icon: 'i-lucide-shield-plus',
            to: accountScopedRoute('custom_roles_list'),
          },
          {
            name: 'Settings Sla',
            visibilityKey: 'Settings:Sla',
            label: t('SIDEBAR.SLA'),
            icon: 'i-lucide-clock-alert',
            to: accountScopedRoute('sla_list'),
          },
          {
            name: 'Conversation Workflow',
            visibilityKey: 'Settings:ConversationWorkflow',
            label: t('SIDEBAR.CONVERSATION_WORKFLOW'),
            icon: 'i-lucide-workflow',
            to: accountScopedRoute('conversation_workflow_index'),
          },
          {
            name: 'Settings Billing',
            visibilityKey: 'Settings:Billing',
            label: t('SIDEBAR.BILLING'),
            icon: 'i-lucide-credit-card',
            to: accountScopedRoute('billing_settings_index'),
          },
        ],
      },
    ],
    uiSettings.value
  );
});
</script>

<template>
  <aside
    v-on-click-outside="[
      closeMobileSidebar,
      { ignore: ['#mobile-sidebar-launcher'] },
    ]"
    class="bg-n-background flex flex-col text-sm pb-px fixed top-0 ltr:left-0 rtl:right-0 h-full z-40 w-[200px] md:w-auto md:relative md:flex-shrink-0 md:ltr:translate-x-0 md:rtl:translate-x-0 ltr:border-r rtl:border-l border-n-weak"
    :class="[
      {
        'shadow-lg md:shadow-none': isMobileSidebarOpen,
        'ltr:-translate-x-full rtl:translate-x-full': !isMobileSidebarOpen,
        'transition-transform duration-200 ease-out md:transition-[width]':
          !isResizing,
      },
    ]"
    :style="isMobile ? undefined : { width: `${sidebarWidth}px` }"
  >
    <section
      class="grid"
      :class="isEffectivelyCollapsed ? 'mt-3 mb-6 gap-4' : 'mt-1 mb-4 gap-2'"
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
          <div class="grid flex-shrink-0 place-content-center size-6">
            <Logo class="size-4" />
          </div>
          <div class="flex-shrink-0 w-px h-3 bg-n-strong" />
          <SidebarAccountSwitcher
            class="flex-grow -mx-1 min-w-0"
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
          <span class="flex-shrink-0 i-lucide-search size-4 text-n-slate-10" />
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
          class="flex items-center justify-center size-8 rounded-lg outline outline-1 outline-n-weak bg-n-button-color transition-all duration-100 ease-out hover:bg-n-alpha-2 dark:hover:bg-n-slate-9/30"
          :title="t('COMBOBOX.SEARCH_PLACEHOLDER')"
        >
          <span class="i-lucide-search size-4 text-n-slate-11" />
        </RouterLink>
        <ComposeConversation align-position="right" @close="onComposeClose">
          <template #trigger="{ toggle, isOpen }">
            <Button
              icon="i-lucide-pen-line"
              color="slate"
              size="sm"
              class="dark:hover:!bg-n-slate-9/30"
              :class="[
                isEffectivelyCollapsed
                  ? '!size-8 !outline-n-weak !text-n-slate-11'
                  : '!h-7 !outline-n-weak !text-n-slate-11',
                { '!bg-n-alpha-2 dark:!bg-n-slate-9/30': isOpen },
              ]"
              @click="onComposeOpen(toggle)"
            />
          </template>
        </ComposeConversation>
      </div>
    </section>
    <nav
      class="grid overflow-y-scroll flex-grow gap-2 pb-5 no-scrollbar min-w-0"
      :class="isEffectivelyCollapsed ? 'px-1' : 'px-2'"
    >
      <ul
        class="flex flex-col gap-1 m-0 list-none min-w-0"
        :class="{ 'items-center': isEffectivelyCollapsed }"
      >
        <SidebarGroup
          v-for="item in menuItems"
          :key="item.name"
          v-bind="item"
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
        :class="isEffectivelyCollapsed ? 'justify-center' : 'justify-between'"
      >
        <SidebarProfileMenu
          :is-collapsed="isEffectivelyCollapsed"
          @open-key-shortcut-modal="emit('openKeyShortcutModal')"
        />
      </div>
    </section>
    <!-- Resize Handle (desktop only) -->
    <div
      class="hidden md:block absolute top-0 h-full w-1 cursor-col-resize z-40 ltr:right-0 rtl:left-0 group"
      @mousedown="onResizeStart"
      @touchstart="onResizeStart"
      @dblclick="onResizeHandleDoubleClick"
    >
      <div
        class="absolute top-0 h-full w-px ltr:right-0 rtl:left-0 bg-transparent group-hover:bg-n-brand transition-colors"
        :class="{ 'bg-n-brand': isResizing }"
      />
    </div>
  </aside>
</template>
