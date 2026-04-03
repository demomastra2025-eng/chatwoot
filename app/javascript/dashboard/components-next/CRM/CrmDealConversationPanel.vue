<script setup>
import { computed, onBeforeUnmount, reactive, watch } from 'vue';
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
  visible: {
    type: Boolean,
    default: false,
  },
});

const emit = defineEmits(['close']);

const { t } = useI18n();
const store = useStore();
const getConversationById = useMapGetter('getConversationById');
const currentChat = useMapGetter('getSelectedChat');

const ui = reactive({
  error: null,
  isLoading: false,
});

const normalizedConversationId = computed(() => {
  const conversationId = Number(props.conversationId);
  return Number.isFinite(conversationId) && conversationId > 0
    ? conversationId
    : 0;
});

const activeConversation = computed(
  () => getConversationById.value(normalizedConversationId.value) || null
);

const isConversationReady = computed(
  () => Number(currentChat.value?.id) === normalizedConversationId.value
);

const clearConversationState = () => {
  store.dispatch('clearSelectedState');
};

const closePanel = () => emit('close');

const activateConversation = async () => {
  if (!props.visible || !normalizedConversationId.value) {
    clearConversationState();
    return;
  }

  ui.error = null;
  ui.isLoading = true;

  try {
    if (!activeConversation.value) {
      await store.dispatch('getConversation', normalizedConversationId.value);
    }

    const conversation =
      getConversationById.value(normalizedConversationId.value) || null;

    if (!conversation) {
      throw new Error(t('CRM.ERRORS.LOAD_TITLE'));
    }

    await store.dispatch('setActiveChat', { data: conversation });
  } catch (error) {
    ui.error = error;
  } finally {
    ui.isLoading = false;
  }
};

watch(
  [() => props.visible, normalizedConversationId],
  ([isVisible, conversationId]) => {
    if (!isVisible || !conversationId) {
      ui.error = null;
      ui.isLoading = false;
      clearConversationState();
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
  >
    <div
      v-if="visible && normalizedConversationId"
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
                    id: normalizedConversationId,
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

          <div
            v-if="ui.isLoading || !isConversationReady"
            class="flex flex-1 items-center justify-center"
          >
            <Spinner class="!h-8 !w-8" />
          </div>

          <SchedulingErrorState
            v-else-if="ui.error"
            class="m-4"
            :title="$t('CRM.ERRORS.LOAD_TITLE')"
            :description="ui.error?.message || $t('CRM.ERRORS.LOAD_TITLE')"
            @retry="activateConversation"
          />

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
