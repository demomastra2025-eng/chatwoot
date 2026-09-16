<script setup>
import Button from 'dashboard/components-next/button/Button.vue';
import ButtonGroup from 'dashboard/components-next/buttonGroup/ButtonGroup.vue';
import { useUISettings } from 'dashboard/composables/useUISettings';
import { useConversationSidepanelAvailability } from 'dashboard/composables/useConversationSidepanelAvailability';
import { computed } from 'vue';
import { useKeyboardEvents } from 'dashboard/composables/useKeyboardEvents';

const { uiSettings, updateUISettings } = useUISettings();
const {
  dealsAvailable: showDealAction,
  touchAvailable: showTouchAction,
  appointmentsAvailable: showAppointmentAction,
} = useConversationSidepanelAvailability();

const isContactSidebarOpen = computed(
  () => uiSettings.value.is_contact_sidebar_open
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
    is_scheduling_appointments_panel_open: false,
    is_touch_sidebar_open: false,
  });
};

const handleConversationSidebarToggle = () => {
  updateUISettings({
    is_contact_sidebar_open: true,
    is_crm_deal_panel_open: false,
    is_scheduling_appointments_panel_open: false,
    is_touch_sidebar_open: false,
  });
};

const openDealsSidebar = () => {
  updateUISettings({
    is_contact_sidebar_open: false,
    is_crm_deal_panel_open: true,
    is_scheduling_appointments_panel_open: false,
    is_touch_sidebar_open: false,
  });
};

const openAppointmentsSidebar = () => {
  updateUISettings({
    is_contact_sidebar_open: false,
    is_crm_deal_panel_open: false,
    is_scheduling_appointments_panel_open: true,
    is_touch_sidebar_open: false,
  });
};

const openTouchEditor = () => {
  updateUISettings({
    is_contact_sidebar_open: false,
    is_crm_deal_panel_open: false,
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
  </ButtonGroup>
</template>
