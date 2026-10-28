<script setup>
import Button from 'dashboard/components-next/button/Button.vue';
import ButtonGroup from 'dashboard/components-next/buttonGroup/ButtonGroup.vue';
import { useConversationSidepanelAvailability } from 'dashboard/composables/useConversationSidepanelAvailability';
import { useKeyboardEvents } from 'dashboard/composables/useKeyboardEvents';

const {
  activePanel,
  closePanel,
  dealsAvailable: showDealAction,
  tasksAvailable: showTaskAction,
  appointmentsAvailable: showAppointmentAction,
  openPanel,
} = useConversationSidepanelAvailability();

const toggleConversationSidebarToggle = () => {
  if (activePanel.value === 'contact') closePanel();
  else openPanel('contact');
};

const openDealsSidebar = () => openPanel('deals');
const openTasksSidebar = () => openPanel('tasks');
const openAppointmentsSidebar = () => openPanel('appointments');

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
        'bg-n-alpha-2 active:shadow-sm': activePanel === 'contact',
      }"
      icon="i-ph-user-bold"
      @click="openPanel('contact')"
    />
    <Button
      v-if="showDealAction"
      v-tooltip.bottom="$t('CRM.DEALS.SIDEBAR_TITLE')"
      ghost
      slate
      sm
      class="!rounded-full transition-all duration-[250ms] ease-out active:!scale-95 active:duration-75"
      :class="{
        'bg-n-alpha-2 active:shadow-sm': activePanel === 'deals',
      }"
      icon="i-lucide-briefcase-business"
      @click="openDealsSidebar"
    />
    <Button
      v-if="showTaskAction"
      v-tooltip.bottom="$t('CRM.TASKS.PANEL_TITLE')"
      ghost
      slate
      sm
      class="!rounded-full transition-all duration-[250ms] ease-out active:!scale-95 active:duration-75"
      :class="{ 'bg-n-alpha-2 active:shadow-sm': activePanel === 'tasks' }"
      icon="i-lucide-list-checks"
      @click="openTasksSidebar"
    />
    <Button
      v-if="showAppointmentAction"
      v-tooltip.bottom="$t('SCHEDULING.DIALOGS.PANEL_TITLE')"
      ghost
      slate
      sm
      class="!rounded-full transition-all duration-[250ms] ease-out active:!scale-95 active:duration-75"
      :class="{
        'bg-n-alpha-2 active:shadow-sm': activePanel === 'appointments',
      }"
      icon="i-lucide-calendar-clock"
      @click="openAppointmentsSidebar"
    />
  </ButtonGroup>
</template>
