import { computed } from 'vue';
import { useMapGetter } from 'dashboard/composables/store';
import { useUISettings } from 'dashboard/composables/useUISettings';
import { FEATURE_FLAGS } from 'dashboard/featureFlags';
import {
  CRM_DEAL_MANAGE_PERMISSIONS,
  SCHEDULING_ACCESS_PERMISSIONS,
} from 'dashboard/constants/permissions';
import { hasPermissions } from 'dashboard/helper/permissionsHelper';

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
  const touchAvailable = computed(() =>
    isFeatureEnabledonAccount.value(
      currentAccountId.value,
      FEATURE_FLAGS.CAMPAIGNS
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
  const activePanel = computed(() => {
    if (uiSettings.value.is_contact_sidebar_open) return 'contact';
    if (uiSettings.value.is_crm_deal_panel_open && dealsAvailable.value) {
      return 'deals';
    }
    if (
      uiSettings.value.is_scheduling_appointments_panel_open &&
      appointmentsAvailable.value
    ) {
      return 'appointments';
    }
    if (uiSettings.value.is_touch_sidebar_open && touchAvailable.value) {
      return 'touch';
    }
    return null;
  });

  return {
    activePanel,
    dealsAvailable,
    touchAvailable,
    appointmentsAvailable,
  };
};
