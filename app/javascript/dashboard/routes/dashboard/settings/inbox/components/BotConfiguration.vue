<script setup>
import { computed, ref, watch } from 'vue';
import { OnClickOutside } from '@vueuse/components';
import { useRoute } from 'vue-router';
import { useI18n } from 'vue-i18n';

import { useAlert } from 'dashboard/composables';
import { useMapGetter, useStore } from 'dashboard/composables/store';

import Avatar from 'dashboard/components-next/avatar/Avatar.vue';
import Button from 'dashboard/components-next/button/Button.vue';
import Checkbox from 'dashboard/components-next/checkbox/Checkbox.vue';
import Icon from 'dashboard/components-next/icon/Icon.vue';
import Policy from 'dashboard/components/policy.vue';
import SelectInput from 'dashboard/components-next/select/Select.vue';
import Spinner from 'dashboard/components-next/spinner/Spinner.vue';

const props = defineProps({
  inbox: {
    type: Object,
    default: () => ({}),
  },
});

const DEFAULT_AUTO_REPLY_MODE = 'always';
const NO_ASSISTANT_VALUE = '';

const store = useStore();
const route = useRoute();
const { t } = useI18n();

const assistantUiFlags = useMapGetter('captainAssistants/getUIFlags');
const assistants = useMapGetter('captainAssistants/getRecords');

const selectedAssistantId = ref(NO_ASSISTANT_VALUE);
const selectedAutoReplyMode = ref(DEFAULT_AUTO_REPLY_MODE);
const selectedReplyToOpenConversations = ref(false);
const isUpdatingConnection = ref(false);
const isUpdatingMode = ref(false);
const isUpdatingOpenConversationReplies = ref(false);
const isAssistantDropdownOpen = ref(false);

const currentInboxId = computed(() =>
  Number(props.inbox?.id || route.params.inboxId)
);
const currentInboxFromStore = computed(() =>
  store.getters['inboxes/getInbox'](currentInboxId.value)
);
const currentInbox = computed(() => {
  const storeInbox = currentInboxFromStore.value || {};
  return storeInbox.id ? storeInbox : props.inbox || {};
});
const connectedAssistant = computed(
  () => currentInbox.value?.captain_assistant || null
);
const connectedAssistantId = computed(
  () => Number(connectedAssistant.value?.id) || null
);
const inboxName = computed(() => currentInbox.value?.name || '');

const isFetching = computed(() =>
  Boolean(assistantUiFlags.value?.fetchingList)
);

const sortedAssistants = computed(() => {
  return [...(assistants.value || [])]
    .filter(
      assistant =>
        assistant?.usage_mode !== 'internal_assistant' ||
        Number(assistant?.id) === connectedAssistantId.value
    )
    .sort((a, b) => (a?.name || '').localeCompare(b?.name || ''));
});

const selectedAssistant = computed(() =>
  sortedAssistants.value.find(
    assistant => String(assistant.id) === selectedAssistantId.value
  )
);
const selectedAssistantName = computed(
  () =>
    selectedAssistant.value?.name ||
    t('CAPTAIN.INBOXES.CHANNEL_SETTINGS.ASSISTANT.NO_AGENT')
);

const currentAutoReplyMode = computed(
  () => currentInbox.value?.captain_auto_reply_mode || DEFAULT_AUTO_REPLY_MODE
);
const currentReplyToOpenConversations = computed(() =>
  Boolean(currentInbox.value?.captain_reply_to_open_conversations)
);

const autoReplyModeOptions = computed(() => [
  {
    value: 'always',
    label: t('CAPTAIN.INBOXES.AUTO_REPLY_MODE.OPTIONS.ALWAYS'),
  },
  {
    value: 'working_hours',
    label: t('CAPTAIN.INBOXES.AUTO_REPLY_MODE.OPTIONS.WORKING_HOURS'),
  },
  {
    value: 'outside_working_hours',
    label: t('CAPTAIN.INBOXES.AUTO_REPLY_MODE.OPTIONS.OUTSIDE_WORKING_HOURS'),
  },
]);

const hasAssistants = computed(() => sortedAssistants.value.length > 0);
const canChangeSettings = computed(
  () => Boolean(currentInboxId.value) && !isFetching.value
);
const isAssistantTriggerDisabled = computed(
  () => isUpdatingConnection.value || !canChangeSettings.value
);
const isAutoReplyModeDisabled = computed(
  () =>
    !selectedAssistantId.value ||
    isUpdatingConnection.value ||
    isUpdatingMode.value ||
    !canChangeSettings.value
);
const isReplyToOpenConversationsDisabled = computed(
  () =>
    !selectedAssistantId.value ||
    isUpdatingConnection.value ||
    isUpdatingOpenConversationReplies.value ||
    !canChangeSettings.value
);

const assistantUsageBadge = assistant => {
  return assistant?.usage_mode === 'internal_assistant'
    ? t('CAPTAIN.ASSISTANTS.FORM.USAGE_MODE.OPTIONS.INTERNAL_ASSISTANT.BADGE')
    : t('CAPTAIN.ASSISTANTS.FORM.USAGE_MODE.OPTIONS.EXTERNAL_AGENT.BADGE');
};

const isAssistantSelected = assistantId => {
  return (
    String(assistantId || NO_ASSISTANT_VALUE) === selectedAssistantId.value
  );
};

const closeAssistantDropdown = () => {
  isAssistantDropdownOpen.value = false;
};

const toggleAssistantDropdown = () => {
  if (isAssistantTriggerDisabled.value) return;
  isAssistantDropdownOpen.value = !isAssistantDropdownOpen.value;
};

const fetchCaptainChannelData = async () => {
  await store.dispatch('captainAssistants/get');
};

const refreshInboxData = async () => {
  await store.dispatch('inboxes/get');
};

const syncLocalStateFromInbox = () => {
  if (!isUpdatingConnection.value) {
    selectedAssistantId.value = connectedAssistantId.value
      ? String(connectedAssistantId.value)
      : NO_ASSISTANT_VALUE;
  }

  if (!isUpdatingMode.value) {
    selectedAutoReplyMode.value = currentAutoReplyMode.value;
  }

  if (!isUpdatingOpenConversationReplies.value) {
    selectedReplyToOpenConversations.value =
      currentReplyToOpenConversations.value;
  }
};

const deleteCurrentConnection = async () => {
  if (!connectedAssistantId.value) {
    return;
  }

  await store.dispatch('captainInboxes/delete', {
    assistantId: connectedAssistantId.value,
    inboxId: currentInboxId.value,
  });
};

const connectSelectedAssistant = async assistantId => {
  if (!assistantId) {
    return;
  }

  await store.dispatch('captainInboxes/create', {
    assistantId: Number(assistantId),
    inboxId: currentInboxId.value,
    autoReplyMode: selectedAutoReplyMode.value || DEFAULT_AUTO_REPLY_MODE,
    replyToOpenConversations: selectedReplyToOpenConversations.value,
  });
};

const handleAssistantSelection = async valueOrEvent => {
  const nextAssistantId = String(
    valueOrEvent?.target
      ? valueOrEvent.target.value
      : (valueOrEvent ?? selectedAssistantId.value)
  );
  const previousAssistantId = connectedAssistantId.value
    ? String(connectedAssistantId.value)
    : NO_ASSISTANT_VALUE;

  if (!canChangeSettings.value || nextAssistantId === previousAssistantId) {
    return;
  }

  isUpdatingConnection.value = true;

  try {
    await deleteCurrentConnection();
    await connectSelectedAssistant(nextAssistantId);
    useAlert(
      nextAssistantId
        ? t('CAPTAIN.INBOXES.CREATE.SUCCESS_MESSAGE')
        : t('CAPTAIN.INBOXES.DELETE.SUCCESS_MESSAGE')
    );
    await refreshInboxData();
  } catch (error) {
    selectedAssistantId.value = previousAssistantId;
    if (previousAssistantId && nextAssistantId) {
      try {
        await connectSelectedAssistant(previousAssistantId);
      } catch {
        // Keep the original failure message; the follow-up refresh below shows the actual server state.
      }
    }
    await refreshInboxData();
    useAlert(
      error?.message ||
        (nextAssistantId
          ? t('CAPTAIN.INBOXES.CREATE.ERROR_MESSAGE')
          : t('CAPTAIN.INBOXES.DELETE.ERROR_MESSAGE'))
    );
  } finally {
    isUpdatingConnection.value = false;
  }
};

const selectAssistant = async assistantId => {
  if (isAssistantTriggerDisabled.value) return;

  const nextAssistantId = assistantId
    ? String(assistantId)
    : NO_ASSISTANT_VALUE;
  selectedAssistantId.value = nextAssistantId;
  closeAssistantDropdown();
  await handleAssistantSelection(nextAssistantId);
};

watch(
  currentInboxId,
  inboxId => {
    if (!inboxId) {
      return;
    }

    fetchCaptainChannelData();
  },
  { immediate: true }
);

watch(
  [connectedAssistantId, currentAutoReplyMode, currentReplyToOpenConversations],
  syncLocalStateFromInbox,
  {
    immediate: true,
  }
);

const updateAutoReplyMode = async event => {
  const nextMode = String(event?.target?.value ?? selectedAutoReplyMode.value);
  if (
    !nextMode ||
    !connectedAssistantId.value ||
    nextMode === currentAutoReplyMode.value ||
    isAutoReplyModeDisabled.value
  ) {
    return;
  }

  const previousMode = currentAutoReplyMode.value;
  isUpdatingMode.value = true;

  try {
    await store.dispatch('captainInboxes/create', {
      assistantId: connectedAssistantId.value,
      inboxId: currentInboxId.value,
      autoReplyMode: nextMode,
      replyToOpenConversations: selectedReplyToOpenConversations.value,
    });
    useAlert(t('CAPTAIN.INBOXES.AUTO_REPLY_MODE.UPDATE.SUCCESS_MESSAGE'));
    await refreshInboxData();
  } catch (error) {
    selectedAutoReplyMode.value = previousMode;
    useAlert(
      error?.message ||
        t('CAPTAIN.INBOXES.AUTO_REPLY_MODE.UPDATE.ERROR_MESSAGE')
    );
  } finally {
    isUpdatingMode.value = false;
  }
};

const updateReplyToOpenConversations = async event => {
  const nextValue = Boolean(
    event?.target
      ? event.target.checked
      : selectedReplyToOpenConversations.value
  );
  if (
    !connectedAssistantId.value ||
    nextValue === currentReplyToOpenConversations.value ||
    isReplyToOpenConversationsDisabled.value
  ) {
    return;
  }

  const previousValue = currentReplyToOpenConversations.value;
  isUpdatingOpenConversationReplies.value = true;

  try {
    await store.dispatch('captainInboxes/create', {
      assistantId: connectedAssistantId.value,
      inboxId: currentInboxId.value,
      autoReplyMode: selectedAutoReplyMode.value || DEFAULT_AUTO_REPLY_MODE,
      replyToOpenConversations: nextValue,
    });
    useAlert(
      t('CAPTAIN.INBOXES.REPLY_TO_OPEN_CONVERSATIONS.UPDATE.SUCCESS_MESSAGE')
    );
    await refreshInboxData();
  } catch (error) {
    selectedReplyToOpenConversations.value = previousValue;
    useAlert(
      error?.message ||
        t('CAPTAIN.INBOXES.REPLY_TO_OPEN_CONVERSATIONS.UPDATE.ERROR_MESSAGE')
    );
  } finally {
    isUpdatingOpenConversationReplies.value = false;
  }
};
</script>

<template>
  <div class="mx-6 max-w-3xl">
    <div
      v-if="isFetching"
      class="flex min-h-32 items-center justify-center rounded-2xl bg-n-solid-1"
    >
      <Spinner />
    </div>

    <section v-else class="rounded-2xl bg-n-solid-1 p-5 md:p-6">
      <div class="mb-5 flex flex-col gap-3">
        <div
          class="grid size-10 place-items-center rounded-2xl bg-n-brand/10 text-n-brand"
        >
          <Icon icon="i-woot-captain" class="size-5" />
        </div>
        <div class="min-w-0">
          <h2 class="text-heading-3 text-n-slate-12">
            {{ t('CAPTAIN.INBOXES.CHANNEL_SETTINGS.TITLE') }}
          </h2>
          <p class="mt-1 max-w-2xl text-sm leading-5 text-n-slate-11">
            {{
              t('CAPTAIN.INBOXES.CHANNEL_SETTINGS.DESCRIPTION', {
                inboxName,
              })
            }}
          </p>
        </div>
      </div>

      <div
        v-if="!hasAssistants"
        class="mb-5 rounded-xl border border-dashed border-n-weak px-4 py-3 text-sm text-n-slate-11"
      >
        <p class="font-medium text-n-slate-12">
          {{ t('CAPTAIN.INBOXES.CHANNEL_SETTINGS.EMPTY_TITLE') }}
        </p>
        <p class="mt-1 text-n-slate-11">
          {{ t('CAPTAIN.INBOXES.CHANNEL_SETTINGS.EMPTY_DESCRIPTION') }}
        </p>
      </div>

      <Policy :permissions="['administrator']" class="block">
        <div
          class="grid grid-cols-1 gap-3 lg:grid-cols-[minmax(0,1fr)_12rem] lg:items-end"
        >
          <div class="flex min-w-0 flex-col gap-1.5">
            <label
              for="captain-inbox-assistant"
              class="text-sm font-medium text-n-slate-12"
            >
              {{ t('CAPTAIN.INBOXES.CHANNEL_SETTINGS.ASSISTANT.LABEL') }}
            </label>
            <OnClickOutside @trigger="closeAssistantDropdown">
              <div class="relative">
                <Button
                  id="captain-inbox-assistant"
                  type="button"
                  variant="outline"
                  color="slate"
                  size="md"
                  trailing-icon
                  icon="i-lucide-chevron-down"
                  class="!h-auto !w-full !justify-between !px-3 !py-2 text-left"
                  data-testid="captain-inbox-assistant"
                  :disabled="isAssistantTriggerDisabled"
                  :aria-expanded="isAssistantDropdownOpen"
                  aria-haspopup="listbox"
                  @click="toggleAssistantDropdown"
                >
                  <span class="flex min-w-0 items-center gap-2">
                    <Avatar
                      v-if="selectedAssistant"
                      :src="selectedAssistant.avatar_url || ''"
                      :name="selectedAssistant.name"
                      :size="24"
                      :icon-name="
                        selectedAssistant.avatar_url ? null : 'i-woot-captain'
                      "
                      rounded-full
                    />
                    <span
                      v-else
                      class="grid size-6 shrink-0 place-items-center rounded-full bg-n-alpha-2 text-n-slate-11"
                    >
                      <Icon icon="i-woot-captain" class="size-3.5" />
                    </span>
                    <span class="min-w-0 truncate text-sm font-medium">
                      {{ selectedAssistantName }}
                    </span>
                  </span>
                </Button>

                <div
                  v-show="isAssistantDropdownOpen"
                  class="absolute left-0 right-0 top-[calc(100%+0.5rem)] z-30 flex max-h-72 flex-col gap-1 overflow-y-auto rounded-xl border border-n-weak bg-n-solid-1 p-2 shadow-lg"
                  role="listbox"
                  aria-labelledby="captain-inbox-assistant"
                >
                  <Button
                    type="button"
                    variant="ghost"
                    color="slate"
                    size="sm"
                    class="!h-auto !justify-between !px-2 !py-2 text-left"
                    :class="{
                      'bg-n-alpha-2': isAssistantSelected(NO_ASSISTANT_VALUE),
                    }"
                    data-testid="captain-inbox-assistant-option-none"
                    @click="selectAssistant(NO_ASSISTANT_VALUE)"
                  >
                    <span class="flex min-w-0 items-center gap-2">
                      <span
                        class="grid size-6 shrink-0 place-items-center rounded-full bg-n-alpha-2 text-n-slate-11"
                      >
                        <Icon icon="i-woot-captain" class="size-3.5" />
                      </span>
                      <span class="min-w-0 truncate text-sm font-medium">
                        {{
                          t(
                            'CAPTAIN.INBOXES.CHANNEL_SETTINGS.ASSISTANT.NO_AGENT'
                          )
                        }}
                      </span>
                    </span>
                    <Icon
                      v-if="isAssistantSelected(NO_ASSISTANT_VALUE)"
                      icon="i-lucide-check"
                      class="size-4 shrink-0 text-n-teal-10"
                    />
                  </Button>

                  <Button
                    v-for="assistant in sortedAssistants"
                    :key="assistant.id"
                    type="button"
                    variant="ghost"
                    color="slate"
                    size="sm"
                    class="!h-auto !justify-between !px-2 !py-2 text-left hover:!bg-n-alpha-2"
                    :class="{
                      'bg-n-alpha-2': isAssistantSelected(assistant.id),
                    }"
                    :data-testid="`captain-inbox-assistant-option-${assistant.id}`"
                    @click="selectAssistant(assistant.id)"
                  >
                    <span class="flex min-w-0 items-center gap-2">
                      <Avatar
                        :src="assistant.avatar_url || ''"
                        :name="assistant.name"
                        :size="24"
                        :icon-name="
                          assistant.avatar_url ? null : 'i-woot-captain'
                        "
                        rounded-full
                      />
                      <span class="flex min-w-0 flex-col text-left">
                        <span
                          class="min-w-0 truncate text-sm font-medium text-n-slate-12"
                        >
                          {{ assistant.name || `#${assistant.id}` }}
                        </span>
                        <span class="text-xs text-n-slate-11">
                          {{ assistantUsageBadge(assistant) }}
                        </span>
                      </span>
                    </span>
                    <Icon
                      v-if="isAssistantSelected(assistant.id)"
                      icon="i-lucide-check"
                      class="size-4 shrink-0 text-n-teal-10"
                    />
                  </Button>
                </div>
              </div>
            </OnClickOutside>
          </div>

          <div class="flex min-w-0 flex-col gap-1.5">
            <label
              for="captain-inbox-auto-reply-mode"
              class="text-sm font-medium text-n-slate-12"
            >
              {{ t('CAPTAIN.INBOXES.AUTO_REPLY_MODE.LABEL') }}
            </label>
            <SelectInput
              id="captain-inbox-auto-reply-mode"
              v-model="selectedAutoReplyMode"
              class="w-full [&_select]:py-2 [&_select]:text-sm"
              data-testid="captain-inbox-auto-reply-mode"
              :options="autoReplyModeOptions"
              :disabled="isAutoReplyModeDisabled"
              @change="updateAutoReplyMode"
            />
          </div>

          <label
            for="captain-inbox-reply-to-open-conversations"
            class="flex cursor-pointer gap-3 rounded-xl border border-n-weak px-3 py-3 lg:col-span-2"
            :class="{
              'cursor-not-allowed opacity-60':
                isReplyToOpenConversationsDisabled,
            }"
          >
            <Checkbox
              id="captain-inbox-reply-to-open-conversations"
              v-model="selectedReplyToOpenConversations"
              class="mt-0.5 shrink-0"
              data-testid="captain-inbox-reply-to-open-conversations"
              :disabled="isReplyToOpenConversationsDisabled"
              @change="updateReplyToOpenConversations"
            />
            <span class="min-w-0">
              <span class="block text-sm font-medium text-n-slate-12">
                {{ t('CAPTAIN.INBOXES.REPLY_TO_OPEN_CONVERSATIONS.LABEL') }}
              </span>
              <span class="mt-1 block text-sm leading-5 text-n-slate-11">
                {{
                  t('CAPTAIN.INBOXES.REPLY_TO_OPEN_CONVERSATIONS.DESCRIPTION')
                }}
              </span>
            </span>
          </label>
        </div>
      </Policy>
    </section>
  </div>
</template>
