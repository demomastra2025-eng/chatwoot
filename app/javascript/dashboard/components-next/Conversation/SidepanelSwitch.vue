<script setup>
import Button from 'dashboard/components-next/button/Button.vue';
import ButtonGroup from 'dashboard/components-next/buttonGroup/ButtonGroup.vue';
import { useUISettings } from 'dashboard/composables/useUISettings';
import { useAccount } from 'dashboard/composables/useAccount';
import { computed } from 'vue';
import { FEATURE_FLAGS } from 'dashboard/featureFlags';
import { useMapGetter } from 'dashboard/composables/store';
import { useKeyboardEvents } from 'dashboard/composables/useKeyboardEvents';
import {
  CRM_DEAL_MANAGE_PERMISSIONS,
  SCHEDULING_ACCESS_PERMISSIONS,
} from 'dashboard/constants/permissions';
import { hasPermissions } from 'dashboard/helper/permissionsHelper';
import {
  buildEffectiveSidebarVisibilitySettings,
  buildSidebarVisibilityState,
  CONVERSATION_APPOINTMENT_STATUSES_VISIBILITY_KEY,
  CONVERSATION_PIPELINES_VISIBILITY_KEY,
} from 'dashboard/components-next/sidebar/sidebarVisibility';

const { uiSettings, updateUISettings } = useUISettings();
const { currentAccount: activeAccount } = useAccount();

const currentAccountId = useMapGetter('getCurrentAccountId');
const currentUser = useMapGetter('getCurrentUser');
const isFeatureEnabledonAccount = useMapGetter(
  'accounts/isFeatureEnabledonAccount'
);

const currentAccountPermissions = computed(() => {
  const currentAccount = currentUser.value?.accounts?.find(
    account => Number(account.id) === Number(currentAccountId.value)
  );

  return currentAccount?.permissions || [];
});
const effectiveSidebarVisibilitySettings = computed(() =>
  buildEffectiveSidebarVisibilitySettings({
    accountId: currentAccountId.value,
    accountSettings: activeAccount.value?.settings || {},
    uiSettings: uiSettings.value,
  })
);
const conversationVisibility = computed(() =>
  buildSidebarVisibilityState(effectiveSidebarVisibilitySettings.value)
);
const isDealPanelVisible = computed(
  () => conversationVisibility.value[CONVERSATION_PIPELINES_VISIBILITY_KEY]
);
const isAppointmentPanelVisible = computed(
  () =>
    conversationVisibility.value[
      CONVERSATION_APPOINTMENT_STATUSES_VISIBILITY_KEY
    ]
);
const showDealAction = computed(
  () =>
    isDealPanelVisible.value &&
    isFeatureEnabledonAccount.value(
      currentAccountId.value,
      FEATURE_FLAGS.CRM_DEALS
    ) &&
    hasPermissions(CRM_DEAL_MANAGE_PERMISSIONS, currentAccountPermissions.value)
);
const showCopilotTab = computed(() =>
  isFeatureEnabledonAccount.value(currentAccountId.value, FEATURE_FLAGS.CAPTAIN)
);
const showTouchAction = computed(() =>
  isFeatureEnabledonAccount.value(
    currentAccountId.value,
    FEATURE_FLAGS.CAMPAIGNS
  )
);
const showAppointmentAction = computed(
  () =>
    isAppointmentPanelVisible.value &&
    isFeatureEnabledonAccount.value(
      currentAccountId.value,
      FEATURE_FLAGS.SCHEDULING
    ) &&
    hasPermissions(
      SCHEDULING_ACCESS_PERMISSIONS,
      currentAccountPermissions.value
    )
);

const isContactSidebarOpen = computed(
  () => uiSettings.value.is_contact_sidebar_open
);
const isCopilotPanelOpen = computed(
  () => uiSettings.value.is_copilot_panel_open
);
const isDealsSidebarOpen = computed(
  () => uiSettings.value.is_crm_deal_panel_open
);
const isAppointmentsSidebarOpen = computed(
  () => uiSettings.value.is_scheduling_appointments_panel_open
);
const isTouchSidebarOpen = computed(
  () => uiSettings.value.is_touch_sidebar_open
);

const toggleConversationSidebarToggle = () => {
  updateUISettings({
    is_contact_sidebar_open: !isContactSidebarOpen.value,
    is_crm_deal_panel_open: false,
    is_copilot_panel_open: false,
    is_scheduling_appointments_panel_open: false,
    is_touch_sidebar_open: false,
  });
};

const handleConversationSidebarToggle = () => {
  updateUISettings({
    is_contact_sidebar_open: true,
    is_crm_deal_panel_open: false,
    is_copilot_panel_open: false,
    is_scheduling_appointments_panel_open: false,
    is_touch_sidebar_open: false,
  });
};

const openDealsSidebar = () => {
  updateUISettings({
    is_contact_sidebar_open: false,
    is_crm_deal_panel_open: true,
    is_copilot_panel_open: false,
    is_scheduling_appointments_panel_open: false,
    is_touch_sidebar_open: false,
  });
};

const openAppointmentsSidebar = () => {
  updateUISettings({
    is_contact_sidebar_open: false,
    is_crm_deal_panel_open: false,
    is_copilot_panel_open: false,
    is_scheduling_appointments_panel_open: true,
    is_touch_sidebar_open: false,
  });
};

const handleCopilotSidebarToggle = () => {
  updateUISettings({
    is_contact_sidebar_open: false,
    is_crm_deal_panel_open: false,
    is_copilot_panel_open: true,
    is_scheduling_appointments_panel_open: false,
    is_touch_sidebar_open: false,
  });
};

const openTouchEditor = () => {
  updateUISettings({
    is_contact_sidebar_open: false,
    is_crm_deal_panel_open: false,
    is_copilot_panel_open: false,
    is_scheduling_appointments_panel_open: false,
    is_touch_sidebar_open: true,
  });
};

const keyboardEvents = {
  'Alt+KeyO': {
    action: toggleConversationSidebarToggle,
  },
};
useKeyboardEvents(keyboardEvents);
</script>

<template>
  <ButtonGroup
    class="flex flex-col justify-center items-center absolute top-36 xl:top-24 ltr:right-2 rtl:left-2 bg-n-solid-2/90 backdrop-blur-lg border border-n-weak/50 rounded-full gap-1.5 p-1.5 shadow-sm transition-shadow duration-200 hover:shadow !z-20"
  >
    <Button
      v-tooltip.top="$t('CONVERSATION.SIDEBAR.CONTACT')"
      ghost
      slate
      sm
      class="!rounded-full transition-all duration-[250ms] ease-out active:!scale-95 active:!brightness-105 active:duration-75"
      :class="{
        'bg-n-alpha-2 active:shadow-sm': isContactSidebarOpen,
      }"
      icon="i-ph-user-bold"
      @click="handleConversationSidebarToggle"
    />
    <Button
      v-if="showDealAction"
      v-tooltip.bottom="$t('CRM.DEALS.SIDEBAR_TITLE')"
      ghost
      slate
      sm
      class="!rounded-full transition-all duration-[250ms] ease-out active:!scale-95 active:duration-75"
      :class="{
        'bg-n-alpha-2 active:shadow-sm': isDealsSidebarOpen,
      }"
      icon="i-lucide-briefcase-business"
      @click="openDealsSidebar"
    />
    <Button
      v-if="showTouchAction"
      v-tooltip.bottom="$t('CONVERSATION.REPLYBOX.CREATE_DELAYED_MESSAGE')"
      ghost
      slate
      sm
      class="!rounded-full transition-all duration-[250ms] ease-out active:!scale-95 active:duration-75"
      :class="{
        'bg-n-alpha-2 active:shadow-sm': isTouchSidebarOpen,
      }"
      icon="i-lucide-timer-reset"
      @click="openTouchEditor"
    />
    <Button
      v-if="showAppointmentAction"
      v-tooltip.bottom="$t('SCHEDULING.DIALOGS.PANEL_TITLE')"
      ghost
      slate
      sm
      class="!rounded-full transition-all duration-[250ms] ease-out active:!scale-95 active:duration-75"
      :class="{
        'bg-n-alpha-2 active:shadow-sm': isAppointmentsSidebarOpen,
      }"
      icon="i-lucide-calendar-clock"
      @click="openAppointmentsSidebar"
    />
    <Button
      v-if="showCopilotTab"
      v-tooltip.bottom="$t('CONVERSATION.SIDEBAR.COPILOT')"
      ghost
      slate
      sm
      class="!rounded-full transition-all duration-[250ms] ease-out active:!scale-95 active:duration-75"
      :class="{
        'bg-n-alpha-2 !text-n-iris-9 active:!brightness-105 active:shadow-sm':
          isCopilotPanelOpen,
      }"
      icon="i-woot-captain"
      @click="handleCopilotSidebarToggle"
    />
  </ButtonGroup>
</template>
