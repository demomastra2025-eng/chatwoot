<script setup>
import { ref, computed, onMounted, watch } from 'vue';
import { useAlert } from 'dashboard/composables';
import { useStore } from 'dashboard/composables/store';
import Copilot from 'dashboard/components-next/copilot/Copilot.vue';
import { useMapGetter } from 'dashboard/composables/store';
import { useUISettings } from 'dashboard/composables/useUISettings';
import { useConfig } from 'dashboard/composables/useConfig';
import { useWindowSize } from '@vueuse/core';
import { vOnClickOutside } from '@vueuse/components';
import { useRoute, useRouter } from 'vue-router';
import { FEATURE_FLAGS } from 'dashboard/featureFlags';
import { executeCaptainUiAction } from 'dashboard/helper/captainUiActions';
import wootConstants from 'dashboard/constants/globals';

defineProps({
  conversationInboxType: {
    type: String,
    default: '',
  },
});

const store = useStore();
const route = useRoute();
const router = useRouter();
const { uiSettings, updateUISettings } = useUISettings();
const { isEnterprise } = useConfig();
const { width: windowWidth } = useWindowSize();
const DEFAULT_PANEL_WIDTH = 320;
const WIDE_PANEL_WIDTH = 360;
const MIN_PANEL_WIDTH = 320;
const MAX_PANEL_WIDTH_RATIO = 0.7;

const assistants = useMapGetter('captainAssistants/getRecords');
const uiFlags = useMapGetter('captainAssistants/getUIFlags');
const inboxAssistant = useMapGetter('getCopilotAssistant');
const currentChat = useMapGetter('getSelectedChat');
const selectedCopilotThreadId = ref(null);
const hydratedRouteThreadId = ref(null);
const hydratingRouteThread = ref(false);

const isSmallScreen = computed(
  () => windowWidth.value < wootConstants.SMALL_SCREEN_BREAKPOINT
);
const defaultPanelWidth = computed(() =>
  windowWidth.value >= 1536 ? WIDE_PANEL_WIDTH : DEFAULT_PANEL_WIDTH
);
const maxPanelWidth = computed(() =>
  Math.max(
    MIN_PANEL_WIDTH,
    Math.floor(windowWidth.value * MAX_PANEL_WIDTH_RATIO)
  )
);
const copilotPanelWidth = computed(() =>
  Math.min(defaultPanelWidth.value, maxPanelWidth.value)
);
const copilotPanelStyle = computed(() => {
  if (isSmallScreen.value) return {};

  return {
    width: `${copilotPanelWidth.value}px`,
    minWidth: `${copilotPanelWidth.value}px`,
    maxWidth: `${maxPanelWidth.value}px`,
  };
});

const messages = computed(() =>
  store.getters['copilotMessages/getMessagesByThreadId'](
    selectedCopilotThreadId.value
  )
);

const currentAccountId = useMapGetter('getCurrentAccountId');
const isFeatureEnabledonAccount = useMapGetter(
  'accounts/isFeatureEnabledonAccount'
);

const selectedAssistantId = ref(null);
const routeCopilotThreadId = computed(() => {
  const raw =
    route.query.copilot_thread_id ?? route.query.copilotThreadId ?? null;
  const parsed = Number.parseInt(raw, 10);
  return Number.isFinite(parsed) && parsed > 0 ? parsed : null;
});
const routeAssistantId = computed(() => {
  const raw = route.query.assistant_id ?? route.query.assistantId ?? null;
  const parsed = Number.parseInt(raw, 10);
  return Number.isFinite(parsed) && parsed > 0 ? parsed : null;
});

const activeAssistant = computed(() => {
  if (selectedAssistantId.value) {
    const selectedAssistant = assistants.value.find(
      a => a.id === selectedAssistantId.value
    );
    if (selectedAssistant) return selectedAssistant;
  }

  const preferredId = uiSettings.value.preferred_captain_assistant_id;

  // If the user has selected a specific assistant, it takes first preference for Copilot.
  if (preferredId) {
    const preferredAssistant = assistants.value.find(a => a.id === preferredId);
    // Return the preferred assistant if found, otherwise continue to next cases
    if (preferredAssistant) return preferredAssistant;
  }

  // If the above is not available, the assistant connected to the inbox takes preference.
  if (inboxAssistant.value) {
    const inboxMatchedAssistant = assistants.value.find(
      a => a.id === inboxAssistant.value.id
    );
    if (inboxMatchedAssistant) return inboxMatchedAssistant;
  }
  // If neither of the above is available, the first assistant in the account takes preference.
  return assistants.value[0];
});
const activeConversationId = computed(
  () =>
    currentChat.value?.active_reply_channel?.conversation_id ||
    currentChat.value?.active_reply_channel_conversation_id ||
    currentChat.value?.conversation_ids?.[0] ||
    currentChat.value?.id
);

const closeCopilotPanel = () => {
  if (isSmallScreen.value && uiSettings.value?.is_copilot_panel_open) {
    updateUISettings({
      is_contact_sidebar_open: false,
      is_copilot_panel_open: false,
      is_crm_deal_panel_open: false,
      is_touch_sidebar_open: false,
    });
  }
};

const handlePanelOutsideClick = event => {
  if (event?.target?.closest?.('[data-copilot-modal]')) return;

  closeCopilotPanel();
};

const setAssistant = async assistant => {
  selectedAssistantId.value = assistant.id;
  await updateUISettings({
    preferred_captain_assistant_id: assistant.id,
  });
};

const shouldShowCopilotPanel = computed(() => {
  if (!isEnterprise) {
    return false;
  }
  const isCaptainEnabled = isFeatureEnabledonAccount.value(
    currentAccountId.value,
    FEATURE_FLAGS.CAPTAIN
  );
  const { is_copilot_panel_open: isCopilotPanelOpen } = uiSettings.value;
  return isCaptainEnabled && isCopilotPanelOpen && !uiFlags.value.fetchingList;
});

const handleReset = () => {
  selectedCopilotThreadId.value = null;
};

const hydrateThreadFromRoute = async () => {
  const threadId = routeCopilotThreadId.value;
  if (!isEnterprise || !threadId) return;
  if (hydratedRouteThreadId.value === threadId) return;
  if (hydratingRouteThread.value) return;

  hydratingRouteThread.value = true;

  try {
    updateUISettings({
      is_contact_sidebar_open: false,
      is_copilot_panel_open: true,
      is_crm_deal_panel_open: false,
      is_touch_sidebar_open: false,
    });

    let thread = store.getters['copilotThreads/getRecord'](threadId);
    if (!thread?.id) {
      thread = await store.dispatch('copilotThreads/show', threadId);
    }

    if (
      !store.getters['copilotMessages/getMessagesByThreadId'](threadId).length
    ) {
      await store.dispatch('copilotMessages/get', threadId);
    }

    selectedCopilotThreadId.value = threadId;
    selectedAssistantId.value = thread?.assistant_id || routeAssistantId.value;
    hydratedRouteThreadId.value = threadId;
  } catch (error) {
    useAlert(error.message);
  } finally {
    hydratingRouteThread.value = false;
  }
};

const sendMessage = async message => {
  try {
    if (selectedCopilotThreadId.value) {
      await store.dispatch('copilotMessages/create', {
        assistant_id: activeAssistant.value.id,
        conversation_id: activeConversationId.value,
        threadId: selectedCopilotThreadId.value,
        message,
      });
    } else {
      const response = await store.dispatch('copilotThreads/create', {
        assistant_id: activeAssistant.value.id,
        conversation_id: activeConversationId.value,
        message,
      });
      selectedCopilotThreadId.value = response.id;
    }
  } catch (error) {
    useAlert(error.message);
  }
};

const handleUiAction = async action => {
  try {
    await executeCaptainUiAction(action, {
      router,
      accountId: currentAccountId.value,
      showConfirmation: useAlert,
    });
  } catch (error) {
    useAlert(error.message);
  }
};

onMounted(() => {
  if (isEnterprise) {
    store.dispatch('captainAssistants/get');
  }
});

watch(
  [routeCopilotThreadId, assistants],
  async () => {
    await hydrateThreadFromRoute();
  },
  { immediate: true }
);
</script>

<template>
  <div
    v-if="shouldShowCopilotPanel"
    v-on-click-outside="[
      handlePanelOutsideClick,
      { ignore: ['[data-copilot-modal]'] },
    ]"
    class="relative bg-n-surface-2 h-full overflow-hidden flex-col fixed top-0 ltr:right-0 rtl:left-0 z-40 w-full transition-transform duration-300 ease-in-out md:static md:shrink-0 ltr:border-l rtl:border-r border-n-weak shadow-lg md:shadow-none"
    :style="copilotPanelStyle"
    :class="[
      {
        'md:flex': shouldShowCopilotPanel,
        'md:hidden': !shouldShowCopilotPanel,
      },
    ]"
  >
    <Copilot
      :messages="messages"
      :conversation-inbox-type="conversationInboxType"
      :assistants="assistants"
      :active-assistant="activeAssistant"
      @set-assistant="setAssistant"
      @send-message="sendMessage"
      @ui-action="handleUiAction"
      @reset="handleReset"
    />
  </div>
  <template v-else />
</template>
