import { computed, shallowRef } from 'vue';
import { useRoute } from 'vue-router';
import { useWindowSize } from '@vueuse/core';
import wootConstants from 'dashboard/constants/globals';
import { useMapGetter } from 'dashboard/composables/store';
import { useUISettings } from 'dashboard/composables/useUISettings';
import { FEATURE_FLAGS } from 'dashboard/featureFlags';
import {
  CRM_DEAL_MANAGE_PERMISSIONS,
  CRM_TASK_VIEW_PERMISSIONS,
  SCHEDULING_ACCESS_PERMISSIONS,
} from 'dashboard/constants/permissions';
import { hasPermissions } from 'dashboard/helper/permissionsHelper';

// A phone panel is an explicit action for the current conversation, not a
// persisted desktop preference. The key also prevents it following navigation
// to another conversation (including between accounts and thread types).
const mobilePanelIntent = shallowRef(null);
export const resetMobileConversationPanel = () => {
  mobilePanelIntent.value = null;
};

const conversationKey = route => {
  const params = route.params || {};
  const id =
    params.communication_thread_id ||
    params.conversation_id ||
    params.conversationId ||
    params.id;
  if (!id) return null;
  const kind = params.communication_thread_id ? 'thread' : 'conversation';
  return `${params.accountId}:${kind}:${id}`;
};

// Single source of truth for the conversation side panels that depend on
// account features and user permissions. Deals and appointments are available
// only when the feature is enabled and the user has the matching permission,
// so a panel flag persisted in UI settings can never open a panel the user
// cannot use.
export const useConversationSidepanelAvailability = () => {
  const { uiSettings, updateUISettings } = useUISettings();
  const route = useRoute();
  const { width } = useWindowSize();
  const isSmallScreen = computed(
    () => width.value <= wootConstants.SMALL_SCREEN_BREAKPOINT
  );
  const currentConversationKey = computed(() => conversationKey(route));
  const currentAccountId = useMapGetter('getCurrentAccountId');
  const currentUser = useMapGetter('getCurrentUser');
  const isFeatureEnabledonAccount = useMapGetter(
    'accounts/isFeatureEnabledonAccount'
  );

  const currentAccountPermissions = computed(() => {
    const account = currentUser.value?.accounts?.find(
      item => Number(item.id) === Number(currentAccountId.value)
    );
    return account?.permissions || [];
  });

  const dealsAvailable = computed(
    () =>
      isFeatureEnabledonAccount.value(
        currentAccountId.value,
        FEATURE_FLAGS.CRM_DEALS
      ) &&
      hasPermissions(
        CRM_DEAL_MANAGE_PERMISSIONS,
        currentAccountPermissions.value
      )
  );

  const appointmentsAvailable = computed(
    () =>
      isFeatureEnabledonAccount.value(
        currentAccountId.value,
        FEATURE_FLAGS.SCHEDULING
      ) &&
      hasPermissions(
        SCHEDULING_ACCESS_PERMISSIONS,
        currentAccountPermissions.value
      )
  );

  const tasksAvailable = computed(
    () =>
      isFeatureEnabledonAccount.value(
        currentAccountId.value,
        FEATURE_FLAGS.CRM_TASKS
      ) &&
      hasPermissions(CRM_TASK_VIEW_PERMISSIONS, currentAccountPermissions.value)
  );

  // Contact, deals and appointments in priority order; null when none of
  // these panels is open and available.
  const persistedPanel = computed(() => {
    const settings = uiSettings.value || {};

    if (settings.is_contact_sidebar_open) return 'contact';
    if (settings.is_crm_deal_panel_open && dealsAvailable.value) {
      return 'deals';
    }
    if (settings.is_crm_task_panel_open && tasksAvailable.value) return 'tasks';
    if (
      settings.is_scheduling_appointments_panel_open &&
      appointmentsAvailable.value
    ) {
      return 'appointments';
    }
    return null;
  });

  const activePanel = computed(() => {
    if (!isSmallScreen.value) return persistedPanel.value;
    if (mobilePanelIntent.value?.key !== currentConversationKey.value)
      return null;
    const panel = mobilePanelIntent.value?.panel;
    if (panel === 'deals' && !dealsAvailable.value) return null;
    if (panel === 'tasks' && !tasksAvailable.value) return null;
    if (panel === 'appointments' && !appointmentsAvailable.value) return null;
    return panel || null;
  });

  const openPanel = (panel, desktopSettings) => {
    if (isSmallScreen.value) {
      mobilePanelIntent.value = { key: currentConversationKey.value, panel };
      return;
    }
    updateUISettings(
      desktopSettings || {
        is_contact_sidebar_open: panel === 'contact',
        is_crm_deal_panel_open: panel === 'deals',
        is_crm_task_panel_open: panel === 'tasks',
        is_scheduling_appointments_panel_open: panel === 'appointments',
      }
    );
  };

  const closePanel = desktopSettings => {
    if (isSmallScreen.value) {
      mobilePanelIntent.value = null;
      return;
    }
    updateUISettings(
      desktopSettings || {
        is_contact_sidebar_open: false,
        is_crm_deal_panel_open: false,
        is_crm_task_panel_open: false,
        is_scheduling_appointments_panel_open: false,
      }
    );
  };

  return {
    activePanel,
    appointmentsAvailable,
    closePanel,
    dealsAvailable,
    tasksAvailable,
    isSmallScreen,
    openPanel,
  };
};
