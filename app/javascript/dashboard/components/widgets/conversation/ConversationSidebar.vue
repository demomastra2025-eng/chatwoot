<script setup>
import { computed } from 'vue';
import { useRouter } from 'vue-router';
import ContactPanel from 'dashboard/routes/dashboard/conversation/ContactPanel.vue';
import CrmConversationDealsSidebar from 'dashboard/components-next/CRM/CrmConversationDealsSidebar.vue';
import SchedulingConversationAppointmentsSidebar from 'dashboard/components-next/Scheduling/SchedulingConversationAppointmentsSidebar.vue';
import TouchEditorDrawer from 'dashboard/components-next/Outbound/TouchEditorDrawer.vue';
import { useUISettings } from 'dashboard/composables/useUISettings';
import { useAccount } from 'dashboard/composables/useAccount';
import { useWindowSize } from '@vueuse/core';
import { vOnClickOutside } from '@vueuse/components';
import wootConstants from 'dashboard/constants/globals';
import {
  buildSidebarVisibilityState,
  CONVERSATION_APPOINTMENT_STATUSES_VISIBILITY_KEY,
  CONVERSATION_PIPELINES_VISIBILITY_KEY,
} from 'dashboard/components-next/sidebar/sidebarVisibility';

const props = defineProps({
  currentChat: {
    required: true,
    type: Object,
  },
});

const router = useRouter();
const { accountScopedRoute } = useAccount();

const { uiSettings, updateUISettings } = useUISettings();
const { width: windowWidth } = useWindowSize();
const clickOutsideOptions = {
  ignore: [
    '[data-modal-safe-interaction]',
    'dialog[open]',
    '.dashboard-combobox-dropdown',
    '.reka-date-time-picker__content',
    '.reka-color-picker__content',
  ],
};

const activeTab = computed(() => {
  const visibility = buildSidebarVisibilityState(uiSettings.value);
  const {
    is_contact_sidebar_open: isContactSidebarOpen,
    is_crm_deal_panel_open: isDealsSidebarOpen,
    is_scheduling_appointments_panel_open: isAppointmentsSidebarOpen,
    is_touch_sidebar_open: isTouchSidebarOpen,
  } = uiSettings.value;

  if (isContactSidebarOpen) {
    return 'contact';
  }
  if (isDealsSidebarOpen && visibility[CONVERSATION_PIPELINES_VISIBILITY_KEY]) {
    return 'deals';
  }
  if (
    isAppointmentsSidebarOpen &&
    visibility[CONVERSATION_APPOINTMENT_STATUSES_VISIBILITY_KEY]
  ) {
    return 'appointments';
  }
  if (isTouchSidebarOpen) return 'touch';
  return null;
});
const sidebarSizeClass =
  'max-w-sm md:w-[320px] md:min-w-[320px] 2xl:min-w-[360px] 2xl:w-[360px]';
const isCommunicationThread = computed(() =>
  Boolean(props.currentChat?.is_communication_thread)
);
const activeReplyChannel = computed(
  () => props.currentChat?.active_reply_channel || {}
);
const activeConversationId = computed(
  () =>
    activeReplyChannel.value?.conversation_id ||
    props.currentChat?.active_reply_channel_conversation_id ||
    props.currentChat?.conversation_ids?.[0] ||
    props.currentChat?.id
);
const activeInboxId = computed(
  () =>
    activeReplyChannel.value?.inbox_id ||
    props.currentChat?.active_reply_channel_inbox_id ||
    props.currentChat?.inbox_id
);
const remindableType = computed(() =>
  isCommunicationThread.value ? 'CommunicationThread' : 'Conversation'
);
const remindableId = computed(() => props.currentChat?.id);

const isSmallScreen = computed(
  () => windowWidth.value < wootConstants.SMALL_SCREEN_BREAKPOINT
);

const closeSidebar = () => {
  if (
    isSmallScreen.value &&
    (uiSettings.value?.is_contact_sidebar_open ||
      uiSettings.value?.is_crm_deal_panel_open ||
      uiSettings.value?.is_scheduling_appointments_panel_open ||
      uiSettings.value?.is_touch_sidebar_open)
  ) {
    updateUISettings({
      is_contact_sidebar_open: false,
      is_copilot_panel_open: false,
      is_crm_deal_panel_open: false,
      is_scheduling_appointments_panel_open: false,
      is_touch_sidebar_open: false,
    });
  }
};

const closeDealsSidebar = () => {
  updateUISettings({
    is_contact_sidebar_open: false,
    is_copilot_panel_open: false,
    is_crm_deal_panel_open: false,
    is_scheduling_appointments_panel_open: false,
    is_touch_sidebar_open: false,
  });
};

const closeAppointmentsSidebar = () => {
  updateUISettings({
    is_contact_sidebar_open: false,
    is_copilot_panel_open: false,
    is_crm_deal_panel_open: false,
    is_scheduling_appointments_panel_open: false,
    is_touch_sidebar_open: false,
  });
};

const closeTouchSidebar = () => {
  updateUISettings({
    is_contact_sidebar_open: false,
    is_copilot_panel_open: false,
    is_crm_deal_panel_open: false,
    is_scheduling_appointments_panel_open: false,
    is_touch_sidebar_open: false,
  });
};

const openTouchesWorkspace = () => {
  router.push(
    accountScopedRoute(
      'outbound_touches_index',
      {},
      {
        conversation_id: activeConversationId.value,
        remindable_id: remindableId.value,
        remindable_type: remindableType.value,
        ...(isCommunicationThread.value
          ? { communication_thread_id: remindableId.value }
          : {}),
      }
    )
  );
};
</script>

<template>
  <div
    v-on-click-outside="[() => closeSidebar(), clickOutsideOptions]"
    class="bg-n-surface-2 h-full overflow-hidden flex flex-col fixed top-0 z-40 w-full transition-transform duration-300 ease-in-out ltr:right-0 rtl:left-0 md:static ltr:border-l rtl:border-r border-n-weak shadow-lg md:shadow-none"
    :class="[
      sidebarSizeClass,
      {
        'translate-x-0': !!activeTab,
        'ltr:translate-x-full rtl:-translate-x-full pointer-events-none md:translate-x-0 md:pointer-events-auto':
          !activeTab,
        'md:flex': !!activeTab,
        'md:hidden': !activeTab,
      },
    ]"
  >
    <div class="flex flex-1 overflow-auto">
      <ContactPanel
        v-show="activeTab === 'contact'"
        :conversation-id="activeConversationId"
        :inbox-id="activeInboxId"
      />
      <div v-if="activeTab === 'deals'" class="min-w-0 flex-1">
        <CrmConversationDealsSidebar
          :current-chat="currentChat"
          @close="closeDealsSidebar"
        />
      </div>
      <div v-if="activeTab === 'appointments'" class="min-w-0 flex-1">
        <SchedulingConversationAppointmentsSidebar
          :current-chat="currentChat"
          @close="closeAppointmentsSidebar"
        />
      </div>
      <div v-if="activeTab === 'touch'" class="min-w-0 flex-1">
        <TouchEditorDrawer
          :model-value="activeTab === 'touch'"
          display-mode="sidebar"
          :conversation-id="activeConversationId"
          :remindable-type="remindableType"
          :remindable-id="remindableId"
          show-all-touches-action
          @close="closeTouchSidebar"
          @saved="closeTouchSidebar"
          @update:model-value="value => !value && closeTouchSidebar()"
          @view-all="openTouchesWorkspace"
        />
      </div>
    </div>
  </div>
</template>
