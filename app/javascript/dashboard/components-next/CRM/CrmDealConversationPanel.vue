<script setup>
import {
  computed,
  defineAsyncComponent,
  onBeforeUnmount,
  provide,
  reactive,
  ref,
  useId,
  watch,
} from 'vue';
import { useEventListener, useMediaQuery } from '@vueuse/core';
import { useI18n } from 'vue-i18n';

import ConversationBox from 'dashboard/components/widgets/conversation/ConversationBox.vue';
import Button from 'dashboard/components-next/button/Button.vue';
import Icon from 'dashboard/components-next/icon/Icon.vue';
import SchedulingErrorState from 'dashboard/components-next/Scheduling/SchedulingErrorState.vue';
import SchedulingSelectField from 'dashboard/components-next/Scheduling/SchedulingSelectField.vue';
import Spinner from 'dashboard/components-next/spinner/Spinner.vue';
import { useStore, useMapGetter } from 'dashboard/composables/store';
import { useConversationSidepanelAvailability } from 'dashboard/composables/useConversationSidepanelAvailability';
import { PERSON_DIALOG_OPENER } from 'dashboard/composables/useOpenPersonDialog';

const props = defineProps({
  sourceDealId: {
    type: [Number, String],
    default: null,
  },
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
  contextLoadError: {
    type: [Object, String],
    default: null,
  },
  selectedContactId: {
    type: [Number, String],
    default: '',
  },
  canManage: {
    type: Boolean,
    default: false,
  },
  loadErrorI18nKey: {
    type: String,
    default: 'CRM.ERRORS.LOAD_TITLE',
  },
  placeholderI18nPrefix: {
    type: String,
    default: 'CRM.DEALS.CONVERSATION_PLACEHOLDER',
  },
  visible: {
    type: Boolean,
    default: false,
  },
  inline: {
    type: Boolean,
    default: false,
  },
  active: {
    type: Boolean,
    default: true,
  },
  showOpenFullScreen: {
    type: Boolean,
    default: false,
  },
  showAppointments: {
    type: Boolean,
    default: true,
  },
});

const emit = defineEmits([
  'addContact',
  'close',
  'dialogCreated',
  'openFullScreen',
  'retryContext',
  'selectContact',
]);

const ConversationSidebar = defineAsyncComponent(
  () =>
    import('dashboard/components/widgets/conversation/ConversationSidebar.vue')
);

const { t } = useI18n();
provide(
  'crmSourceDealId',
  computed(() => props.sourceDealId)
);
const store = useStore();
const getConversationById = useMapGetter('getConversationById');
const getAllConversations = useMapGetter('getAllConversations');
const currentChat = useMapGetter('getSelectedChat');
const {
  activePanel,
  appointmentsAvailable,
  openPanel,
  closePanel: closeConversationSidepanel,
} = useConversationSidepanelAvailability();
const appointmentsSidebarId = `crm-deal-appointments-${useId()}`;
const appointmentsOpened = ref(false);

const translateDynamicKey = key => {
  // eslint-disable-next-line @intlify/vue-i18n/no-dynamic-keys
  return t(key);
};
const loadErrorText = computed(() =>
  translateDynamicKey(props.loadErrorI18nKey)
);
const placeholderText = key =>
  translateDynamicKey(`${props.placeholderI18nPrefix}.${key}`);

// Same breakpoint as the `lg:` classes of the inline layout below.
const isWideViewport = useMediaQuery('(min-width: 1024px)');
// Below `lg` the inline chat is hidden while the Deal tab is open. A hidden
// chat must not be the selected conversation: with zero-size message metrics
// it counts as "scrolled to the bottom" and would scroll and mark every new
// message as read for a tab nobody is looking at. It activates when its tab
// opens (or the screen is wide enough to show it) and releases when it hides.
const isChatDisplayed = computed(
  () => props.visible && (!props.inline || props.active || isWideViewport.value)
);

const ui = reactive({
  error: null,
  isLoading: false,
});
const activationRequestId = ref(0);
// The person the dialog is held with when the deal or the appointment has no linked chat yet: their thread when they have one,
// else the empty screen of a draft. Nothing is made until the first message, call or note.
const selectedPlaceholderContactId = ref('');
const personThreadDisplayId = ref(0);

const normalizePositiveNumber = value => {
  const normalizedValue = Number(String(value || '').replace(/[^\d]/g, ''));
  return Number.isFinite(normalizedValue) && normalizedValue > 0
    ? normalizedValue
    : 0;
};

// Conversation API/store records expose the public display id as `id`.
const resolvedConversationDisplayId = conversation =>
  normalizePositiveNumber(
    conversation?.display_id || conversation?.displayId || conversation?.id
  );

const normalizedConversationId = computed(() =>
  normalizePositiveNumber(props.conversationId)
);
const normalizedConversationDisplayId = computed(() =>
  normalizePositiveNumber(props.conversationDisplayId)
);
const normalizedCommunicationThreadId = computed(() =>
  normalizePositiveNumber(props.communicationThreadId)
);
const normalizedCommunicationThreadDisplayIdFromProps = computed(() =>
  normalizePositiveNumber(props.communicationThreadDisplayId)
);
const normalizedCommunicationThreadDisplayId = computed(
  () =>
    normalizedCommunicationThreadDisplayIdFromProps.value ||
    personThreadDisplayId.value
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
// The deal or the appointment itself points at a chat; otherwise the panel opens the dialog of the person on its own.
const isLinkedByParent = computed(
  () =>
    !!normalizedCommunicationThreadDisplayIdFromProps.value ||
    !!normalizedCommunicationThreadId.value ||
    !!normalizedConversationDisplayId.value ||
    !!normalizedConversationId.value
);
const contactOptions = computed(() =>
  props.contacts.map(contact => ({
    label: contact.label || contact.name || String(contact.id || ''),
    value: contact.id || contact.value,
  }))
);
const conversationByDisplayId = computed(() => {
  if (!normalizedConversationDisplayId.value) return null;

  return (getAllConversations.value || []).find(conversation => {
    return (
      resolvedConversationDisplayId(conversation) ===
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

  if (normalizedConversationDisplayId.value) {
    return conversationByDisplayId.value;
  }

  return getConversationById.value(normalizedConversationId.value) || null;
});
const activeCommunicationThread = computed(() => {
  if (!communicationThreadApiId.value) {
    return null;
  }

  if (normalizedCommunicationThreadDisplayId.value) {
    return communicationThreadByDisplayId.value;
  }

  return (
    getConversationById.value(
      normalizedCommunicationThreadId.value,
      'communication_thread'
    ) || null
  );
});
const activeChat = computed(() =>
  isCommunicationThreadTarget.value
    ? activeCommunicationThread.value
    : activeConversation.value
);

// A person without a dialog opens as the draft of a dialog; a person with one opens that dialog.
const draftOfSelectedPerson = computed(
  () =>
    !hasLinkedChat.value &&
    !!currentChat.value?.is_draft &&
    String(currentChat.value.person_contact_id) ===
      String(selectedPlaceholderContactId.value)
);

const isConversationReady = computed(() => {
  // The empty screen of the person is ready as soon as it is open.
  if (draftOfSelectedPerson.value) return true;
  const currentChatId = normalizePositiveNumber(currentChat.value?.id);
  const currentChatDisplayId = resolvedConversationDisplayId(currentChat.value);
  const currentChatThreadId = normalizePositiveNumber(
    currentChat.value?.communication_thread_id ||
      currentChat.value?.communicationThreadId
  );

  if (isCommunicationThreadTarget.value) {
    const matchesTarget = normalizedCommunicationThreadDisplayId.value
      ? currentChatDisplayId === normalizedCommunicationThreadDisplayId.value ||
        currentChatThreadId === normalizedCommunicationThreadDisplayId.value
      : currentChatId === normalizedCommunicationThreadId.value ||
        currentChatThreadId === normalizedCommunicationThreadId.value;

    return currentChat.value?.is_communication_thread && matchesTarget;
  }

  const matchesTarget = normalizedConversationDisplayId.value
    ? currentChatDisplayId === normalizedConversationDisplayId.value
    : currentChatId === normalizedConversationId.value;

  return !currentChat.value?.is_communication_thread && matchesTarget;
});

const canOpenAppointments = computed(
  () =>
    props.showAppointments &&
    appointmentsAvailable.value &&
    isChatDisplayed.value &&
    hasLinkedChat.value &&
    isConversationReady.value &&
    !ui.isLoading &&
    !ui.error
);
// A saved Communications sidebar preference must not cover the embedded chat
// until the user opens it here. The shared sidebar still owns patient context.
const showAppointmentsSidebar = computed(
  () =>
    appointmentsOpened.value &&
    canOpenAppointments.value &&
    activePanel.value === 'appointments'
);
const closeAppointmentsSidebar = () => {
  appointmentsOpened.value = false;
  closeConversationSidepanel({ is_scheduling_appointments_panel_open: false });
};
const toggleAppointmentsSidebar = () => {
  if (!canOpenAppointments.value) return;
  if (showAppointmentsSidebar.value) {
    closeAppointmentsSidebar();
    return;
  }

  appointmentsOpened.value = true;
  openPanel('appointments');
};

const clearConversationState = () => {
  store.dispatch('clearSelectedState');
};

const closePanel = () => emit('close');
const updateSelectedContact = contactId => {
  selectedPlaceholderContactId.value = contactId || '';
  personThreadDisplayId.value = 0;
  store.dispatch('clearSelectedState');
  emit('selectContact', selectedPlaceholderContactId.value);
};

let personDialogRequestId = 0;
const openPersonDialogForSelectedContact = async () => {
  const contactId = selectedPlaceholderContactId.value;
  if (!contactId || hasLinkedChat.value || !isChatDisplayed.value) return;
  if (draftOfSelectedPerson.value) return;

  personDialogRequestId += 1;
  const requestId = personDialogRequestId;
  ui.error = null;
  ui.isLoading = true;
  try {
    const result = await store.dispatch('openPersonDialog', { contactId });
    if (requestId !== personDialogRequestId || !result) return;
    if (result.communicationThreadId) {
      personThreadDisplayId.value = normalizePositiveNumber(
        result.communicationThreadId
      );
    }
  } catch (error) {
    if (requestId === personDialogRequestId) ui.error = error;
  } finally {
    if (requestId === personDialogRequestId) ui.isLoading = false;
  }
};

// «Написать» inside the panel (for a child: the one the number belongs to) opens the dialog in the panel, not on a page of its own.
provide(PERSON_DIALOG_OPENER, contactId => {
  personThreadDisplayId.value = 0;
  selectedPlaceholderContactId.value = contactId;
  store.dispatch('clearSelectedState');
  return openPersonDialogForSelectedContact();
});

const contextLoadErrorDescription = computed(() =>
  typeof props.contextLoadError === 'string'
    ? props.contextLoadError
    : props.contextLoadError?.message || loadErrorText.value
);

const invalidateActivation = () => {
  activationRequestId.value += 1;
};

const resetPanelState = () => {
  ui.error = null;
  ui.isLoading = false;
  appointmentsOpened.value = false;
};

const activateConversation = async () => {
  if (!isChatDisplayed.value || !chatApiId.value) {
    return;
  }
  // The chat is already the open one (a draft that just became the dialog): nothing to open again.
  if (
    isConversationReady.value &&
    currentChat.value?.dataFetched !== undefined
  ) {
    ui.isLoading = false;
    return;
  }

  const requestId = activationRequestId.value + 1;
  const targetApiId = chatApiId.value;
  const targetIsCommunicationThread = isCommunicationThreadTarget.value;
  activationRequestId.value = requestId;
  ui.error = null;
  ui.isLoading = true;

  const isCurrentActivation = () =>
    requestId === activationRequestId.value &&
    isChatDisplayed.value &&
    chatApiId.value === targetApiId &&
    isCommunicationThreadTarget.value === targetIsCommunicationThread;

  try {
    if (!isCurrentActivation()) return;
    let conversation = activeChat.value;

    if (!conversation) {
      conversation =
        (await store.dispatch(
          targetIsCommunicationThread
            ? 'getCommunicationThread'
            : 'getConversation',
          targetApiId
        )) || activeChat.value;
    }

    if (!isCurrentActivation()) return;

    if (!conversation) {
      throw new Error(loadErrorText.value);
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
  personThreadDisplayId.value = 0;
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
  [selectedPlaceholderContactId, isChatDisplayed, hasLinkedChat],
  () => openPersonDialogForSelectedContact(),
  { immediate: true }
);

// The first message, call or note made the dialog: this panel and the page behind it follow it.
watch(
  () => currentChat.value?.id,
  () => {
    const chat = currentChat.value;
    if (
      !selectedPlaceholderContactId.value ||
      !chat?.id ||
      chat.is_draft ||
      !chat.is_communication_thread ||
      String(chat.contact_id ?? chat.meta?.sender?.id) !==
        String(selectedPlaceholderContactId.value)
    ) {
      return;
    }
    const threadId = normalizePositiveNumber(chat.id);
    if (!threadId || personThreadDisplayId.value === threadId) return;
    if (normalizedCommunicationThreadDisplayIdFromProps.value === threadId) {
      return;
    }

    personThreadDisplayId.value = threadId;
    emit('dialogCreated', {
      communicationThreadId: threadId,
      contactId: selectedPlaceholderContactId.value,
    });
  }
);

watch(
  [isChatDisplayed, chatApiId, isCommunicationThreadTarget],
  ([isVisible, apiId, isThread], previousValues = []) => {
    const [wasVisible, previousApiId, wasThread] = previousValues;
    if (!isVisible || !apiId) {
      invalidateActivation();
      resetPanelState();
      // A tab switch hides the panel without leaving the page: release the
      // selected conversation (leaving through the transition clears it too).
      if (wasVisible && props.visible) clearConversationState();
      return;
    }

    if (wasVisible && (previousApiId !== apiId || wasThread !== isThread)) {
      invalidateActivation();
      resetPanelState();
      if (!isConversationReady.value) clearConversationState();
    }

    activateConversation();
  },
  { immediate: true }
);

useEventListener(document, 'keydown', event => {
  if (event.key === 'Escape' && showAppointmentsSidebar.value) {
    closeAppointmentsSidebar();
    return;
  }
  // The inline panel sits beside the deal card instead of covering it, so an
  // Escape meant for the composer, a menu or a dialog must not leave the page.
  if (event.key === 'Escape' && props.visible && !props.inline) {
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
      class="min-w-0 bg-n-solid-2 md:bg-transparent"
      :class="
        inline
          ? [
              'relative min-h-0 flex-1 lg:h-full lg:w-2/3 lg:flex-none',
              active ? 'flex' : 'hidden lg:flex',
            ]
          : 'fixed inset-0 z-[120] md:static md:inset-auto md:z-auto md:h-full md:flex-1'
      "
    >
      <div class="flex h-full min-w-0 w-full justify-end">
        <aside
          class="flex h-full min-w-0 w-full flex-col overflow-hidden bg-n-solid-2 md:flex-1 md:bg-transparent"
        >
          <header
            v-if="hasLinkedChat && (showOpenFullScreen || canOpenAppointments)"
            class="flex flex-wrap justify-end gap-2 border-b border-n-weak bg-n-surface-1 px-4 py-2"
          >
            <Button
              v-if="canOpenAppointments"
              size="sm"
              color="slate"
              variant="ghost"
              icon="i-lucide-calendar-clock"
              :label="$t('SCHEDULING.DIALOGS.PANEL_TITLE')"
              :aria-controls="appointmentsSidebarId"
              :aria-expanded="showAppointmentsSidebar"
              @click="toggleAppointmentsSidebar"
            />
            <Button
              v-if="showOpenFullScreen"
              size="sm"
              color="slate"
              variant="ghost"
              icon="i-lucide-external-link"
              :label="$t('CRM.DEALS.CONVERSATION_PLACEHOLDER.OPEN_FULL_SCREEN')"
              @click="emit('openFullScreen')"
            />
          </header>
          <div
            v-if="!isLinkedByParent && contactOptions.length > 1"
            class="border-b border-n-weak bg-n-surface-1 px-4 py-2"
          >
            <SchedulingSelectField
              :label="placeholderText('CONTACT')"
              :model-value="selectedPlaceholderContactId"
              :options="contactOptions"
              @update:model-value="updateSelectedContact"
            />
          </div>
          <SchedulingErrorState
            v-if="!hasLinkedChat && contextLoadError"
            class="m-4"
            :title="loadErrorText"
            :description="contextLoadErrorDescription"
            @retry="emit('retryContext')"
          />

          <div
            v-else-if="!hasLinkedChat && !contactOptions.length"
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
                  {{ placeholderText('TITLE') }}
                </h3>
                <p class="text-sm leading-6 text-n-slate-11">
                  {{ placeholderText('NO_CONTACT_DESCRIPTION') }}
                </p>
              </div>

              <div class="flex justify-center">
                <Button
                  :label="placeholderText('ADD_CONTACT')"
                  icon="i-lucide-user-plus"
                  :disabled="!canManage"
                  @click="emit('addContact')"
                />
              </div>
            </div>
          </div>

          <SchedulingErrorState
            v-else-if="ui.error"
            class="m-4"
            :title="loadErrorText"
            :description="ui.error?.message || loadErrorText"
            @retry="activateConversation"
          />

          <div
            v-else-if="ui.isLoading || !isConversationReady"
            class="flex flex-1 items-center justify-center"
          >
            <Spinner class="!h-8 !w-8" />
          </div>

          <div
            v-else-if="isChatDisplayed"
            class="relative flex min-h-0 min-w-0 flex-1"
          >
            <ConversationBox
              class="flex-1"
              :inbox-id="currentChat.inbox_id"
              :is-on-expanded-layout="false"
            />
            <ConversationSidebar
              v-if="showAppointmentsSidebar"
              :id="appointmentsSidebarId"
              class="!absolute inset-y-0 !z-30 !max-w-full"
              role="dialog"
              :aria-label="$t('SCHEDULING.DIALOGS.PANEL_TITLE')"
              :current-chat="currentChat"
            />
          </div>
        </aside>
      </div>
    </div>
  </Transition>
</template>
