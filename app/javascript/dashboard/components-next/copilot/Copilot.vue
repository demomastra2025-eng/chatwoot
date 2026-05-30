<script setup>
import { nextTick, ref, watch, computed } from 'vue';
import { useTrack } from 'dashboard/composables';
import { COPILOT_EVENTS } from 'dashboard/helper/AnalyticsHelper/events';
import { useUISettings } from 'dashboard/composables/useUISettings';
import { useRoute } from 'vue-router';
import { markCaptainCopilotPanelClosed } from 'dashboard/helper/captainCopilotPanel';

import CopilotInput from './CopilotInput.vue';
import CopilotLoader from './CopilotLoader.vue';
import CopilotAgentMessage from './CopilotAgentMessage.vue';
import CopilotAssistantMessage from './CopilotAssistantMessage.vue';
import CopilotThinkingGroup from './CopilotThinkingGroup.vue';
import ToggleCopilotAssistant from './ToggleCopilotAssistant.vue';
import CopilotEmptyState from './CopilotEmptyState.vue';
import SidebarActionsHeader from 'dashboard/components-next/SidebarActionsHeader.vue';
import TeleportWithDirection from 'dashboard/components-next/TeleportWithDirection.vue';
import { buildCopilotThinkingTraceMessages } from 'dashboard/components-next/message/helpers/captainToolTrace';
import { useI18n } from 'vue-i18n';

const props = defineProps({
  messages: {
    type: Array,
    default: () => [],
  },
  conversationInboxType: {
    type: String,
    required: true,
  },
  assistants: {
    type: Array,
    default: () => [],
  },
  activeAssistant: {
    type: Object,
    default: () => ({}),
  },
});

const emit = defineEmits(['sendMessage', 'reset', 'setAssistant', 'uiAction']);

const { t } = useI18n();
const route = useRoute();

const sendMessage = message => {
  emit('sendMessage', message);
  useTrack(COPILOT_EVENTS.SEND_MESSAGE);
};

const chatContainer = ref(null);
const modalChatContainer = ref(null);
const isModalOpen = ref(false);

const scrollToBottom = async () => {
  await nextTick();
  if (chatContainer.value) {
    chatContainer.value.scrollTop = chatContainer.value.scrollHeight;
  }
  if (modalChatContainer.value) {
    modalChatContainer.value.scrollTop = modalChatContainer.value.scrollHeight;
  }
};

const groupedMessages = computed(() => {
  const result = [];
  let thinkingGroup = [];
  props.messages.forEach(message => {
    if (message.message_type === 'assistant_thinking') {
      thinkingGroup.push(message);
    } else {
      if (thinkingGroup.length > 0) {
        result.push({
          id: thinkingGroup[0].id,
          message_type: 'thinking_group',
          messages: buildCopilotThinkingTraceMessages(thinkingGroup),
        });
        thinkingGroup = [];
      }
      result.push(message);
    }
  });
  if (thinkingGroup.length > 0) {
    result.push({
      id: thinkingGroup[0].id,
      message_type: 'thinking_group',
      messages: buildCopilotThinkingTraceMessages(thinkingGroup),
    });
  }
  return result;
});

const isLastMessageFromAssistant = computed(() => {
  return (
    groupedMessages.value[groupedMessages.value.length - 1].message_type ===
    'assistant'
  );
});

const { updateUISettings } = useUISettings();

const closeCopilotPanel = () => {
  markCaptainCopilotPanelClosed(route);

  updateUISettings({
    is_copilot_panel_open: false,
    is_contact_sidebar_open: false,
    is_crm_deal_panel_open: false,
    is_touch_sidebar_open: false,
  });
};

const handleSidebarAction = action => {
  if (action === 'reset') {
    emit('reset');
    return;
  }

  if (action === 'open_modal') {
    isModalOpen.value = true;
  }
};

const hasAssistants = computed(() => props.assistants.length > 0);
const hasMessages = computed(() => props.messages.length > 0);
const copilotButtons = computed(() => [
  {
    key: 'reset',
    icon: 'i-lucide-refresh-ccw',
    tooltip: t('CAPTAIN.COPILOT.RESET'),
  },
  {
    key: 'open_modal',
    icon: 'i-lucide-maximize-2',
    tooltip: t('CAPTAIN.COPILOT.OPEN_MODAL'),
  },
]);
const modalButtons = computed(() => [
  {
    key: 'reset',
    icon: 'i-lucide-refresh-ccw',
    tooltip: t('CAPTAIN.COPILOT.RESET'),
  },
]);
watch(
  [() => props.messages],
  () => {
    scrollToBottom();
  },
  { deep: true }
);

watch(isModalOpen, () => {
  scrollToBottom();
});
</script>

<template>
  <div class="flex flex-col h-full text-sm leading-6 tracking-tight w-full">
    <SidebarActionsHeader
      :title="$t('CAPTAIN.COPILOT.TITLE')"
      :buttons="copilotButtons"
      @click="handleSidebarAction"
      @close="closeCopilotPanel"
    />
    <div
      ref="chatContainer"
      class="flex-1 flex px-4 py-4 overflow-y-auto items-start"
    >
      <div v-if="hasMessages" class="space-y-6 flex-1 flex flex-col w-full">
        <template v-for="(item, index) in groupedMessages" :key="item.id">
          <CopilotAgentMessage
            v-if="item.message_type === 'user'"
            :message="item.message"
          />
          <CopilotAssistantMessage
            v-else-if="item.message_type === 'assistant'"
            :message="item.message"
            :is-last-message="index === groupedMessages.length - 1"
            :conversation-inbox-type="conversationInboxType"
            @ui-action="$event => emit('uiAction', $event)"
          />
          <CopilotThinkingGroup
            v-else
            :messages="item.messages"
            :default-collapsed="isLastMessageFromAssistant"
          />
        </template>

        <CopilotLoader v-if="!isLastMessageFromAssistant" />
      </div>
      <CopilotEmptyState
        v-else
        :has-assistants="hasAssistants"
        @use-suggestion="sendMessage"
      />
    </div>

    <div class="mx-3 mt-px mb-2">
      <div class="flex items-center gap-2 justify-between w-full mb-1">
        <ToggleCopilotAssistant
          v-if="assistants.length > 1"
          :assistants="assistants"
          :active-assistant="activeAssistant"
          @set-assistant="$event => emit('setAssistant', $event)"
        />
        <div v-else />
      </div>
      <CopilotInput
        v-if="hasAssistants"
        class="mb-1 w-full"
        @send="sendMessage"
      />
    </div>
  </div>
  <TeleportWithDirection to="body">
    <div
      v-if="isModalOpen"
      data-copilot-modal
      class="fixed inset-0 z-[120] flex items-center justify-center bg-n-alpha-black2 p-6 backdrop-blur-[4px]"
      @click.self="isModalOpen = false"
    >
      <section
        class="flex h-[82vh] w-[70vw] max-w-[calc(100vw-3rem)] min-w-0 flex-col overflow-hidden rounded-xl border border-n-weak bg-n-surface-2 shadow-2xl"
      >
        <SidebarActionsHeader
          :title="$t('CAPTAIN.COPILOT.TITLE')"
          :buttons="modalButtons"
          @click="handleSidebarAction"
          @close="isModalOpen = false"
        />
        <div
          ref="modalChatContainer"
          class="flex flex-1 items-start overflow-y-auto px-5 py-5"
        >
          <div v-if="hasMessages" class="flex w-full flex-1 flex-col space-y-6">
            <template v-for="(item, index) in groupedMessages" :key="item.id">
              <CopilotAgentMessage
                v-if="item.message_type === 'user'"
                :message="item.message"
              />
              <CopilotAssistantMessage
                v-else-if="item.message_type === 'assistant'"
                :message="item.message"
                :is-last-message="index === groupedMessages.length - 1"
                :conversation-inbox-type="conversationInboxType"
                @ui-action="$event => emit('uiAction', $event)"
              />
              <CopilotThinkingGroup
                v-else
                :messages="item.messages"
                :default-collapsed="isLastMessageFromAssistant"
              />
            </template>

            <CopilotLoader v-if="!isLastMessageFromAssistant" />
          </div>
          <CopilotEmptyState
            v-else
            :has-assistants="hasAssistants"
            @use-suggestion="sendMessage"
          />
        </div>

        <div class="mx-4 mb-3 mt-px">
          <div class="mb-1 flex w-full items-center justify-between gap-2">
            <ToggleCopilotAssistant
              v-if="assistants.length > 1"
              :assistants="assistants"
              :active-assistant="activeAssistant"
              @set-assistant="$event => emit('setAssistant', $event)"
            />
            <div v-else />
          </div>
          <CopilotInput
            v-if="hasAssistants"
            class="mb-1 w-full"
            @send="sendMessage"
          />
        </div>
      </section>
    </div>
  </TeleportWithDirection>
</template>
