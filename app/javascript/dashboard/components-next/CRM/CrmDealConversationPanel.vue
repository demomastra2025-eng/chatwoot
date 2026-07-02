<script setup>
import { computed, onBeforeUnmount, reactive, ref, watch } from 'vue';
import { useEventListener } from '@vueuse/core';
import { useI18n } from 'vue-i18n';

import ConversationBox from 'dashboard/components/widgets/conversation/ConversationBox.vue';
import Button from 'dashboard/components-next/button/Button.vue';
import Icon from 'dashboard/components-next/icon/Icon.vue';
import SchedulingErrorState from 'dashboard/components-next/Scheduling/SchedulingErrorState.vue';
import SchedulingSelectField from 'dashboard/components-next/Scheduling/SchedulingSelectField.vue';
import Spinner from 'dashboard/components-next/spinner/Spinner.vue';
import { useStore, useMapGetter } from 'dashboard/composables/store';

const props = defineProps({
  communicationThreadDisplayId: {
    type: [Number, String],
    default: '',
  },
  communicationThreadId: {
    type: [Number, String],
    default: '',
  },
  conversationId: {
    type: [Number, String],
    default: '',
  },
  conversationDisplayId: {
    type: [Number, String],
    default: '',
  },
  contacts: {
    type: Array,
    default: () => [],
  },
  contactableInboxes: {
    type: Array,
    default: () => [],
  },
  selectedContactId: {
    type: [Number, String],
    default: '',
  },
  canManage: {
    type: Boolean,
    default: false,
  },
  isCreatingConversation: {
    type: Boolean,
    default: false,
  },
  isLoadingInboxes: {
    type: Boolean,
    default: false,
  },
  isLoadingCommunicationThread: {
    type: Boolean,
    default: false,
  },
  visible: {
    type: Boolean,
    default: false,
  },
});

const emit = defineEmits([
  'addContact',
  'close',
  'createConversation',
  'selectContact',
]);

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
const selectedPlaceholderContactId = ref('');
const selectedInboxId = ref('');

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
const normalizedCommunicationThreadId = computed(() =>
  normalizePositiveNumber(props.communicationThreadId)
);
const normalizedCommunicationThreadDisplayId = computed(() =>
  normalizePositiveNumber(props.communicationThreadDisplayId)
);
const isCommunicationThreadTarget = computed(
  () =>
    !!normalizedCommunicationThreadDisplayId.value ||
    !!normalizedCommunicationThreadId.value
);
const conversationApiId = computed(
  () => normalizedConversationDisplayId.value || normalizedConversationId.value
);
const communicationThreadApiId = computed(
  () =>
    normalizedCommunicationThreadDisplayId.value ||
    normalizedCommunicationThreadId.value
);
const chatApiId = computed(() =>
  isCommunicationThreadTarget.value
    ? communicationThreadApiId.value
    : conversationApiId.value
);
const hasLinkedChat = computed(() => !!chatApiId.value);
const contactOptions = computed(() =>
  props.contacts.map(contact => ({
    label: contact.label || contact.name || String(contact.id || ''),
    value: contact.id || contact.value,
  }))
);
const inboxOptions = computed(() =>
  props.contactableInboxes.map(inbox => ({
    icon: inbox.icon,
    label: inbox.label || inbox.name || String(inbox.id || inbox.value || ''),
    value: inbox.value || inbox.id,
  }))
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
const communicationThreadByDisplayId = computed(() => {
  if (!normalizedCommunicationThreadDisplayId.value) return null;

  return (getAllConversations.value || []).find(conversation => {
    return (
      conversation.is_communication_thread &&
      normalizePositiveNumber(
        conversation.display_id || conversation.communication_thread_id
      ) === normalizedCommunicationThreadDisplayId.value
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
const activeCommunicationThread = computed(() => {
  if (!communicationThreadApiId.value) {
    return null;
  }

  return (
    getConversationById.value(
      communicationThreadApiId.value,
      'communication_thread'
    ) ||
    getConversationById.value(
      normalizedCommunicationThreadId.value,
      'communication_thread'
    ) ||
    communicationThreadByDisplayId.value ||
    null
  );
});
const activeChat = computed(() =>
  isCommunicationThreadTarget.value
    ? activeCommunicationThread.value
    : activeConversation.value
);

const isConversationReady = computed(() => {
  const currentChatId = normalizePositiveNumber(currentChat.value?.id);
  const currentChatDisplayId = normalizePositiveNumber(
    currentChat.value?.display_id || currentChat.value?.displayId
  );
  const currentChatThreadId = normalizePositiveNumber(
    currentChat.value?.communication_thread_id ||
      currentChat.value?.communicationThreadId
  );

  const candidateConversationIds = new Set(
    (isCommunicationThreadTarget.value
      ? [
          normalizedCommunicationThreadId.value,
          normalizedCommunicationThreadDisplayId.value,
          communicationThreadApiId.value,
        ]
      : [
          normalizedConversationId.value,
          normalizedConversationDisplayId.value,
          conversationApiId.value,
        ]
    ).filter(Boolean)
  );

  if (isCommunicationThreadTarget.value) {
    return (
      currentChat.value?.is_communication_thread &&
      (candidateConversationIds.has(currentChatId) ||
        candidateConversationIds.has(currentChatDisplayId) ||
        candidateConversationIds.has(currentChatThreadId))
    );
  }

  return (
    !currentChat.value?.is_communication_thread &&
    (candidateConversationIds.has(currentChatId) ||
      (normalizedConversationDisplayId.value &&
        currentChatDisplayId === normalizedConversationDisplayId.value))
  );
});

const clearConversationState = () => {
  store.dispatch('clearSelectedState');
};

const closePanel = () => emit('close');
const selectedContact = computed(() =>
  props.contacts.find(
    contact =>
      Number(contact.id || contact.value) ===
      Number(selectedPlaceholderContactId.value)
  )
);
const selectedInbox = computed(() =>
  props.contactableInboxes.find(
    inbox => Number(inbox.value || inbox.id) === Number(selectedInboxId.value)
  )
);
const canCreateConversation = computed(
  () =>
    props.canManage &&
    !!selectedPlaceholderContactId.value &&
    !!selectedInboxId.value &&
    !props.isCreatingConversation &&
    !props.isLoadingInboxes &&
    !props.isLoadingCommunicationThread
);

const updateSelectedContact = contactId => {
  selectedPlaceholderContactId.value = contactId || '';
  selectedInboxId.value = '';
  emit('selectContact', selectedPlaceholderContactId.value);
};

const createConversation = () => {
  if (!canCreateConversation.value) return;

  emit('createConversation', {
    contact: selectedContact.value,
    contactId: selectedPlaceholderContactId.value,
    inbox: selectedInbox.value,
    inboxId: selectedInboxId.value,
  });
};

const invalidateActivation = () => {
  activationRequestId.value += 1;
};

const resetPanelState = () => {
  ui.error = null;
  ui.isLoading = false;
};

const activateConversation = async () => {
  if (!props.visible || !chatApiId.value) {
    return;
  }

  const requestId = activationRequestId.value + 1;
  activationRequestId.value = requestId;
  ui.error = null;
  ui.isLoading = true;

  try {
    if (
      requestId !== activationRequestId.value ||
      !props.visible ||
      !chatApiId.value
    ) {
      return;
    }
    let conversation = activeChat.value;

    if (!conversation) {
      conversation =
        (await store.dispatch(
          isCommunicationThreadTarget.value
            ? 'getCommunicationThread'
            : 'getConversation',
          chatApiId.value
        )) || activeChat.value;
    }

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
  [contactOptions, () => props.selectedContactId],
  ([options, nextSelectedContactId]) => {
    if (hasLinkedChat.value) return;

    const normalizedSelectedContactId = Number(nextSelectedContactId);
    const currentContactId = Number(selectedPlaceholderContactId.value);
    const optionIds = options.map(option => Number(option.value));
    const fallbackContactId =
      Number.isFinite(normalizedSelectedContactId) &&
      normalizedSelectedContactId > 0 &&
      optionIds.includes(normalizedSelectedContactId)
        ? normalizedSelectedContactId
        : optionIds[0] || '';

    if (Number(fallbackContactId || 0) !== currentContactId) {
      updateSelectedContact(fallbackContactId);
    }
  },
  { immediate: true }
);

watch(
  inboxOptions,
  options => {
    if (hasLinkedChat.value) return;

    const currentInboxId = Number(selectedInboxId.value);
    const optionIds = options.map(option => Number(option.value));

    if (!optionIds.includes(currentInboxId)) {
      selectedInboxId.value = optionIds[0] || '';
    }
  },
  { immediate: true }
);

watch(
  [() => props.visible, chatApiId],
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
      v-if="visible"
      class="fixed inset-0 z-[120] bg-n-solid-2 md:static md:inset-auto md:z-auto md:h-full md:min-w-0 md:flex-1 md:bg-transparent"
    >
      <div class="flex h-full w-full justify-end">
        <aside
          class="flex h-full w-full flex-col overflow-hidden bg-n-solid-2 md:min-w-0 md:flex-1 md:bg-transparent"
        >
          <div
            v-if="!hasLinkedChat"
            class="flex h-full flex-1 items-center justify-center px-6 py-8"
          >
            <div class="grid w-full max-w-md gap-5 text-center">
              <div
                class="mx-auto grid size-12 place-items-center rounded-full bg-n-alpha-black2 text-n-slate-11"
              >
                <Icon icon="i-lucide-message-square-plus" class="size-6" />
              </div>

              <div class="grid gap-2">
                <h3 class="text-base font-semibold text-n-slate-12">
                  {{ $t('CRM.DEALS.CONVERSATION_PLACEHOLDER.TITLE') }}
                </h3>
                <p class="text-sm leading-6 text-n-slate-11">
                  {{
                    contactOptions.length
                      ? $t('CRM.DEALS.CONVERSATION_PLACEHOLDER.DESCRIPTION')
                      : $t(
                          'CRM.DEALS.CONVERSATION_PLACEHOLDER.NO_CONTACT_DESCRIPTION'
                        )
                  }}
                </p>
              </div>

              <div v-if="!contactOptions.length" class="flex justify-center">
                <Button
                  :label="$t('CRM.DEALS.CONVERSATION_PLACEHOLDER.ADD_CONTACT')"
                  icon="i-lucide-user-plus"
                  :disabled="!canManage"
                  @click="emit('addContact')"
                />
              </div>

              <div v-else class="grid gap-3 text-left">
                <SchedulingSelectField
                  :label="$t('CRM.DEALS.CONVERSATION_PLACEHOLDER.CONTACT')"
                  :model-value="selectedPlaceholderContactId"
                  :options="contactOptions"
                  :disabled="isCreatingConversation"
                  @update:model-value="updateSelectedContact"
                />
                <SchedulingSelectField
                  :label="$t('CRM.DEALS.CONVERSATION_PLACEHOLDER.INBOX')"
                  :model-value="selectedInboxId"
                  :options="inboxOptions"
                  :disabled="
                    isCreatingConversation ||
                    isLoadingInboxes ||
                    isLoadingCommunicationThread
                  "
                  :empty-state="
                    $t('CRM.DEALS.CONVERSATION_PLACEHOLDER.NO_INBOXES')
                  "
                  @update:model-value="selectedInboxId = $event"
                />
                <Button
                  :label="
                    $t('CRM.DEALS.CONVERSATION_PLACEHOLDER.CREATE_DIALOG')
                  "
                  icon="i-lucide-message-square-plus"
                  :is-loading="isCreatingConversation"
                  :disabled="!canCreateConversation"
                  @click="createConversation"
                />
              </div>
            </div>
          </div>

          <SchedulingErrorState
            v-else-if="ui.error"
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
