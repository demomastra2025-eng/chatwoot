<script setup>
import { computed, ref, watch } from 'vue';
import { OnClickOutside } from '@vueuse/components';
import { useRoute } from 'vue-router';
import { useI18n } from 'vue-i18n';

import { useAlert } from 'dashboard/composables';
import { useMapGetter, useStore } from 'dashboard/composables/store';
import { VOICE_CHANNEL_TYPE } from 'dashboard/helper/captainChannelMatrix';

import Avatar from 'dashboard/components-next/avatar/Avatar.vue';
import Button from 'dashboard/components-next/button/Button.vue';
import Icon from 'dashboard/components-next/icon/Icon.vue';
import Policy from 'dashboard/components/policy.vue';
import SelectInput from 'dashboard/components-next/select/Select.vue';
import Spinner from 'dashboard/components-next/spinner/Spinner.vue';
import { activeExternalAssistants } from 'dashboard/components-next/captain/assistant/assistantAccess';

// Only voice inboxes have an AI agent editor here: the voice agent is not a
// row of «ИИ-агенты → Каналы». AI agents of text channels are set only in that
// grid, so for a text inbox this component renders nothing and writes nothing.

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
const isSaving = ref(false);
const isAssistantDropdownOpen = ref(false);
let settingsIdentity = 0;

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
const isVoiceInbox = computed(
  () => currentInbox.value?.channel_type === VOICE_CHANNEL_TYPE
);

const isFetching = computed(() =>
  Boolean(assistantUiFlags.value?.fetchingList)
);

const sortedAssistants = computed(() => {
  return activeExternalAssistants(assistants.value || []).sort((a, b) =>
    (a?.name || '').localeCompare(b?.name || '')
  );
});

const selectedAssistant = computed(
  () =>
    (assistants.value || []).find(
      assistant => String(assistant.id) === selectedAssistantId.value
    ) ||
    (String(connectedAssistantId.value) === selectedAssistantId.value
      ? connectedAssistant.value
      : null)
);
const selectedAssistantName = computed(
  () =>
    selectedAssistant.value?.name ||
    t('CAPTAIN.INBOXES.CHANNEL_SETTINGS.ASSISTANT.NO_AGENT')
);

const currentAutoReplyMode = computed(
  () => currentInbox.value?.captain_auto_reply_mode || DEFAULT_AUTO_REPLY_MODE
);
const hasChanges = computed(
  () =>
    selectedAssistantId.value !== String(connectedAssistantId.value || '') ||
    selectedAutoReplyMode.value !== currentAutoReplyMode.value
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
  () => isVoiceInbox.value && Boolean(currentInboxId.value) && !isFetching.value
);
const isAssistantTriggerDisabled = computed(
  () => isSaving.value || !canChangeSettings.value
);
const isAutoReplyModeDisabled = computed(
  () => !selectedAssistantId.value || isAssistantTriggerDisabled.value
);

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
  selectedAssistantId.value = connectedAssistantId.value
    ? String(connectedAssistantId.value)
    : NO_ASSISTANT_VALUE;
  selectedAutoReplyMode.value = currentAutoReplyMode.value;
  closeAssistantDropdown();
};

const deleteCurrentConnection = async (assistantId, inboxId) => {
  if (!assistantId) {
    return;
  }

  await store.dispatch('captainInboxes/delete', {
    assistantId,
    inboxId,
  });
};

const connectSelectedAssistant = async (
  assistantId,
  inboxId,
  autoReplyMode
) => {
  if (!assistantId) {
    return;
  }

  await store.dispatch('captainInboxes/create', {
    assistantId: Number(assistantId),
    inboxId,
    autoReplyMode,
  });
};

const saveChannelSettings = async () => {
  if (!canChangeSettings.value || !hasChanges.value || isSaving.value) return;
  const inboxId = currentInboxId.value;
  const currentIdentity = settingsIdentity;
  const nextAssistantId = selectedAssistantId.value;
  const nextMode = selectedAutoReplyMode.value || DEFAULT_AUTO_REPLY_MODE;
  const previousAssistantId = connectedAssistantId.value
    ? String(connectedAssistantId.value)
    : NO_ASSISTANT_VALUE;

  const previousMode = currentAutoReplyMode.value;
  isSaving.value = true;

  try {
    if (nextAssistantId !== previousAssistantId)
      await deleteCurrentConnection(Number(previousAssistantId), inboxId);
    await connectSelectedAssistant(nextAssistantId, inboxId, nextMode);
    await refreshInboxData();
    if (currentIdentity === settingsIdentity) {
      syncLocalStateFromInbox();
      useAlert(t('CAPTAIN.INBOXES.CHANNEL_SETTINGS.SAVE_SUCCESS'));
    }
  } catch (error) {
    if (previousAssistantId && nextAssistantId !== previousAssistantId) {
      try {
        await connectSelectedAssistant(
          previousAssistantId,
          inboxId,
          previousMode
        );
      } catch {
        // Keep the original failure message; the follow-up refresh below shows the actual server state.
      }
    }
    await refreshInboxData();
    if (currentIdentity === settingsIdentity) {
      syncLocalStateFromInbox();
      useAlert(
        error?.message || t('CAPTAIN.INBOXES.CHANNEL_SETTINGS.SAVE_ERROR')
      );
    }
  } finally {
    if (currentIdentity === settingsIdentity) isSaving.value = false;
  }
};

const selectAssistant = assistantId => {
  if (isAssistantTriggerDisabled.value) return;

  const nextAssistantId = assistantId
    ? String(assistantId)
    : NO_ASSISTANT_VALUE;
  selectedAssistantId.value = nextAssistantId;
  closeAssistantDropdown();
};

watch(
  [currentInboxId, isVoiceInbox],
  ([inboxId, isVoice]) => {
    settingsIdentity += 1;
    isSaving.value = false;
    syncLocalStateFromInbox();
    if (!inboxId || !isVoice) {
      return;
    }

    fetchCaptainChannelData();
  },
  { immediate: true }
);

watch(
  [connectedAssistantId, currentAutoReplyMode],
  (_values, [previousAssistantId, previousMode]) => {
    const draftWasSaved =
      selectedAssistantId.value === String(previousAssistantId || '') &&
      selectedAutoReplyMode.value === previousMode;
    if (!isSaving.value && draftWasSaved) syncLocalStateFromInbox();
  }
);
</script>

<template>
  <div v-if="isVoiceInbox" class="mx-6 max-w-3xl">
    <div
      v-if="isFetching"
      class="flex min-h-32 items-center justify-center rounded-2xl bg-n-solid-1"
    >
      <Spinner />
    </div>

    <section v-else class="py-4">
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
            />
          </div>
        </div>
        <div class="mt-5 flex justify-end gap-2">
          <Button
            variant="ghost"
            color="slate"
            :label="t('CAPTAIN.FORM.CANCEL')"
            :disabled="!hasChanges || isSaving"
            data-testid="captain-inbox-cancel"
            @click="syncLocalStateFromInbox"
          />
          <Button
            :label="t('CAPTAIN.ASSISTANTS.FORM.SAVE')"
            :disabled="!hasChanges || !canChangeSettings || isSaving"
            :is-loading="isSaving"
            data-testid="captain-inbox-save"
            @click="saveChannelSettings"
          />
        </div>
      </Policy>
    </section>
  </div>
</template>
