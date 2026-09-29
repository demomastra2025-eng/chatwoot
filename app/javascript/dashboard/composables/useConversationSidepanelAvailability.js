import { computed } from 'vue';
import { useMapGetter } from 'dashboard/composables/store';
import { useUISettings } from 'dashboard/composables/useUISettings';
import { FEATURE_FLAGS } from 'dashboard/featureFlags';
import {
  CRM_DEAL_MANAGE_PERMISSIONS,
  SCHEDULING_ACCESS_PERMISSIONS,
} from 'dashboard/constants/permissions';
import { hasPermissions } from 'dashboard/helper/permissionsHelper';

// Single source of truth for the conversation side panels that depend on
// account features and user permissions. Deals and appointments are available
// only when the feature is enabled and the user has the matching permission,
// so a panel flag persisted in UI settings can never open a panel the user
// cannot use. The touch panel and Copilot keep their own handling.
export const useConversationSidepanelAvailability = () => {
  const { uiSettings } = useUISettings();
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

  // Contact, deals and appointments in priority order; null when none of
  // these panels is open and available.
  const activePanel = computed(() => {
    const settings = uiSettings.value || {};

    if (settings.is_contact_sidebar_open) return 'contact';
    if (settings.is_crm_deal_panel_open && dealsAvailable.value) {
      return 'deals';
    }
    if (
      settings.is_scheduling_appointments_panel_open &&
      appointmentsAvailable.value
    ) {
      return 'appointments';
    }
    return null;
  });

  return {
    activePanel,
    appointmentsAvailable,
    dealsAvailable,
  };
};
