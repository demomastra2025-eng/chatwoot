<script setup>
import { computed, onBeforeUnmount, reactive, ref, watch } from 'vue';
import { useEventListener } from '@vueuse/core';
import { useI18n } from 'vue-i18n';

import Button from 'dashboard/components-next/button/Button.vue';
import ConversationBox from 'dashboard/components/widgets/conversation/ConversationBox.vue';
import SchedulingErrorState from 'dashboard/components-next/Scheduling/SchedulingErrorState.vue';
import Spinner from 'dashboard/components-next/spinner/Spinner.vue';
import { useStore, useMapGetter } from 'dashboard/composables/store';

const props = defineProps({
  conversationId: {
    type: [Number, String],
    default: '',
  },
  conversationDisplayId: {
    type: [Number, String],
    default: '',
  },
  visible: {
    type: Boolean,
    default: false,
  },
});

const emit = defineEmits(['close']);

const { t } = useI18n();
const store = useStore();
const getConversationById = useMapGetter('getConversationById');
const getAllConversations = useMapGetter('getAllConversations');
const currentChat = useMapGetter('getSelectedChat');

const ui = reactive({
  error: null,
  isLoading: false,
});
const activationRequestId = ref(0);

const normalizePositiveNumber = value => {
  const normalizedValue = Number(String(value || '').replace(/[^\d]/g, ''));
  return Number.isFinite(normalizedValue) && normalizedValue > 0
    ? normalizedValue
    : 0;
};

const normalizedConversationId = computed(() =>
  normalizePositiveNumber(props.conversationId)
);
const normalizedConversationDisplayId = computed(() =>
  normalizePositiveNumber(props.conversationDisplayId)
);
const conversationApiId = computed(
  () => normalizedConversationDisplayId.value || normalizedConversationId.value
);
const conversationLabelId = computed(
  () => normalizedConversationDisplayId.value || normalizedConversationId.value
);
const conversationByDisplayId = computed(() => {
  if (!normalizedConversationDisplayId.value) return null;

  return (getAllConversations.value || []).find(conversation => {
    return (
      normalizePositiveNumber(conversation.display_id) ===
      normalizedConversationDisplayId.value
    );
  });
});

const activeConversation = computed(() => {
  if (!conversationApiId.value) {
    return null;
  }

  return (
    getConversationById.value(conversationApiId.value) ||
    getConversationById.value(normalizedConversationId.value) ||
    conversationByDisplayId.value ||
    null
  );
});

const isConversationReady = computed(() => {
  const currentChatId = normalizePositiveNumber(currentChat.value?.id);
  const currentChatDisplayId = normalizePositiveNumber(
    currentChat.value?.display_id || currentChat.value?.displayId
  );

  const candidateConversationIds = new Set(
    [
      normalizedConversationId.value,
      normalizedConversationDisplayId.value,
      conversationApiId.value,
    ].filter(Boolean)
  );

  return (
    candidateConversationIds.has(currentChatId) ||
    (normalizedConversationDisplayId.value &&
      currentChatDisplayId === normalizedConversationDisplayId.value)
  );
});

const clearConversationState = () => {
  store.dispatch('clearSelectedState');
};

const closePanel = () => emit('close');

const invalidateActivation = () => {
  activationRequestId.value += 1;
};

const resetPanelState = () => {
  ui.error = null;
  ui.isLoading = false;
};

const activateConversation = async () => {
  if (!props.visible || !conversationApiId.value) {
    return;
  }

  const requestId = activationRequestId.value + 1;
  activationRequestId.value = requestId;
  ui.error = null;
  ui.isLoading = true;

  try {
    if (!activeConversation.value) {
      await store.dispatch('getConversation', conversationApiId.value);
    }

    if (
      requestId !== activationRequestId.value ||
      !props.visible ||
      !conversationApiId.value
    ) {
      return;
    }

    const conversation = activeConversation.value;

    if (!conversation) {
      throw new Error(t('CRM.ERRORS.LOAD_TITLE'));
    }

    await store.dispatch('setActiveChat', { data: conversation });
  } catch (error) {
    if (requestId !== activationRequestId.value) {
      return;
    }

    ui.error = error;
  } finally {
    if (requestId === activationRequestId.value) {
      ui.isLoading = false;
    }
  }
};

const handleAfterLeave = () => {
  resetPanelState();
  clearConversationState();
};

watch(
  [() => props.visible, conversationApiId],
  ([isVisible, apiId]) => {
    if (!isVisible || !apiId) {
      invalidateActivation();
      resetPanelState();
      return;
    }

    activateConversation();
  },
  { immediate: true }
);

useEventListener(document, 'keydown', event => {
  if (event.key === 'Escape' && props.visible) {
    closePanel();
  }
});

onBeforeUnmount(() => {
  invalidateActivation();
  clearConversationState();
});
</script>

<template>
  <Transition
    enter-active-class="transition-all duration-200 ease-out"
    enter-from-class="translate-x-8 opacity-0"
    enter-to-class="translate-x-0 opacity-100"
    leave-active-class="transition-all duration-150 ease-in"
    leave-from-class="translate-x-0 opacity-100"
    leave-to-class="translate-x-8 opacity-0"
    @after-leave="handleAfterLeave"
  >
    <div
      v-if="visible && conversationApiId"
      class="fixed inset-0 z-[120] bg-black/35 backdrop-blur-[4px] md:absolute md:inset-y-0 md:left-auto md:right-[22rem] md:z-30 md:bg-transparent md:backdrop-blur-0 xl:right-[28rem]"
    >
      <div class="flex h-full w-full justify-end md:pointer-events-none">
        <aside
          class="pointer-events-auto flex h-full w-full flex-col overflow-hidden border border-n-weak bg-n-solid-2 shadow-2xl md:w-[22rem] md:min-w-[22rem] xl:w-[28rem] xl:min-w-[28rem]"
        >
          <header
            class="flex items-start justify-between gap-4 border-b border-n-weak bg-n-surface-1 px-6 py-4"
          >
            <div class="flex flex-col gap-1">
              <h3 class="mb-0 text-lg font-semibold text-n-slate-12">
                {{ $t('CRM.GENERAL.CHAT') }}
              </h3>
              <p class="mb-0 text-sm text-n-slate-11">
                {{
                  $t('CRM.TIMELINE.CONVERSATION', {
                    id: conversationLabelId,
                  })
                }}
              </p>
            </div>
            <Button
              size="sm"
              variant="ghost"
              color="slate"
              icon="i-lucide-x"
              @click="closePanel"
            />
          </header>

          <SchedulingErrorState
            v-if="ui.error"
            class="m-4"
            :title="$t('CRM.ERRORS.LOAD_TITLE')"
            :description="ui.error?.message || $t('CRM.ERRORS.LOAD_TITLE')"
            @retry="activateConversation"
          />

          <div
            v-else-if="ui.isLoading || !isConversationReady"
            class="flex flex-1 items-center justify-center"
          >
            <Spinner class="!h-8 !w-8" />
          </div>

          <div v-else class="flex min-h-0 flex-1">
            <ConversationBox
              class="flex-1"
              :inbox-id="currentChat.inbox_id"
              :is-on-expanded-layout="false"
            />
          </div>
        </aside>
      </div>
    </div>
  </Transition>
</template>
