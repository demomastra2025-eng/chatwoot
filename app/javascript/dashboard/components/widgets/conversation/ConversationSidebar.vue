<script setup>
import { computed } from 'vue';
import ContactPanel from 'dashboard/routes/dashboard/conversation/ContactPanel.vue';
import EntityTouchesCard from 'dashboard/components-next/Outbound/EntityTouchesCard.vue';
import { useUISettings } from 'dashboard/composables/useUISettings';
import { useWindowSize } from '@vueuse/core';
import { vOnClickOutside } from '@vueuse/components';
import wootConstants from 'dashboard/constants/globals';

defineProps({
  currentChat: {
    required: true,
    type: Object,
  },
});

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
  const {
    is_contact_sidebar_open: isContactSidebarOpen,
    is_touch_sidebar_open: isTouchSidebarOpen,
  } = uiSettings.value;

  if (isContactSidebarOpen) {
    return 'contact';
  }
  if (isTouchSidebarOpen) return 'touch';
  return null;
});

const isSmallScreen = computed(
  () => windowWidth.value < wootConstants.SMALL_SCREEN_BREAKPOINT
);

const closeSidebar = () => {
  if (
    isSmallScreen.value &&
    (uiSettings.value?.is_contact_sidebar_open ||
      uiSettings.value?.is_touch_sidebar_open)
  ) {
    updateUISettings({
      is_contact_sidebar_open: false,
      is_copilot_panel_open: false,
      is_crm_deal_panel_open: false,
      is_touch_sidebar_open: false,
    });
  }
};
</script>

<template>
  <div
    v-on-click-outside="[() => closeSidebar(), clickOutsideOptions]"
    class="bg-n-surface-2 h-full overflow-hidden flex flex-col fixed top-0 z-40 w-full max-w-sm transition-transform duration-300 ease-in-out ltr:right-0 rtl:left-0 md:static md:w-[320px] md:min-w-[320px] ltr:border-l rtl:border-r border-n-weak 2xl:min-w-[360px] 2xl:w-[360px] shadow-lg md:shadow-none"
    :class="[
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
        :conversation-id="currentChat.id"
        :inbox-id="currentChat.inbox_id"
      />
      <div v-if="activeTab === 'touch'" class="min-w-0 flex-1 p-3">
        <EntityTouchesCard
          :conversation-id="currentChat.id"
          :title="$t('CONVERSATION.REPLYBOX.CREATE_DELAYED_MESSAGE')"
          :description="$t('CONVERSATION.REPLYBOX.DELAYED_MESSAGE_DESCRIPTION')"
          remindable-type="Conversation"
          :remindable-id="currentChat.id"
        />
      </div>
    </div>
  </div>
</template>
