<script setup>
import { computed, ref, watch } from 'vue';
import { useRoute } from 'vue-router';
import { useI18n } from 'vue-i18n';

import { useAlert } from 'dashboard/composables';
import { useMapGetter, useStore } from 'dashboard/composables/store';

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
const isUpdatingConnection = ref(false);
const isUpdatingMode = ref(false);

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

const assistantOptions = computed(() => [
  {
    value: NO_ASSISTANT_VALUE,
    label: t('CAPTAIN.INBOXES.CHANNEL_SETTINGS.ASSISTANT.NO_AGENT'),
  },
  ...sortedAssistants.value.map(assistant => ({
    value: String(assistant.id),
    label: assistant.name || `#${assistant.id}`,
  })),
]);

const currentAutoReplyMode = computed(
  () => currentInbox.value?.captain_auto_reply_mode || DEFAULT_AUTO_REPLY_MODE
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
  {
    value: 'never',
    label: t('CAPTAIN.INBOXES.AUTO_REPLY_MODE.OPTIONS.NEVER'),
  },
]);

const hasAssistants = computed(() => sortedAssistants.value.length > 0);
const canChangeSettings = computed(
  () => Boolean(currentInboxId.value) && !isFetching.value
);
const isAutoReplyModeDisabled = computed(
  () =>
    !selectedAssistantId.value ||
    isUpdatingConnection.value ||
    isUpdatingMode.value ||
    !canChangeSettings.value
);

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
  });
};

const handleAssistantSelection = async event => {
  const nextAssistantId = String(
    event?.target?.value ?? selectedAssistantId.value
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

watch([connectedAssistantId, currentAutoReplyMode], syncLocalStateFromInbox, {
  immediate: true,
});

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
            <SelectInput
              id="captain-inbox-assistant"
              v-model="selectedAssistantId"
              class="w-full"
              data-testid="captain-inbox-assistant"
              :options="assistantOptions"
              :disabled="isUpdatingConnection || !canChangeSettings"
              @change="handleAssistantSelection"
            />
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
        </div>
      </Policy>
    </section>
  </div>
</template>
