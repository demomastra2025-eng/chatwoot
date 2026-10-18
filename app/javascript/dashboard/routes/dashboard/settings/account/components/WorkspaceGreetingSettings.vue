<script setup>
import { computed, ref, watch } from 'vue';
import { useI18n } from 'vue-i18n';
import { useAlert } from 'dashboard/composables';
import { useMapGetter, useStore } from 'dashboard/composables/store';
import { INBOX_TYPES } from 'dashboard/helper/inbox';
import Button from 'dashboard/components-next/button/Button.vue';
import SectionLayout from './SectionLayout.vue';

const props = defineProps({
  disabled: {
    type: Boolean,
    default: false,
  },
});

const { t } = useI18n();
const store = useStore();
const inboxes = useMapGetter('inboxes/getInboxes');

const EXCLUDED_CHANNEL_TYPES = [INBOX_TYPES.VOICE, INBOX_TYPES.EMAIL];

const textInboxes = computed(() =>
  (inboxes.value || []).filter(
    inbox => !EXCLUDED_CHANNEL_TYPES.includes(inbox.channel_type)
  )
);

const greetingEnabled = ref(false);
const greetingMessage = ref('');
const selectedInboxIds = ref([]);
const isSaving = ref(false);

const hydrateFromInboxes = list => {
  const eligible = (list || []).filter(
    inbox => !EXCLUDED_CHANNEL_TYPES.includes(inbox.channel_type)
  );
  const enabledInboxes = eligible.filter(inbox => inbox.greeting_enabled);
  greetingEnabled.value = enabledInboxes.length > 0;
  selectedInboxIds.value = enabledInboxes.map(inbox => inbox.id);

  const firstWithMessage =
    enabledInboxes.find(inbox => inbox.greeting_message?.trim()) ||
    eligible.find(inbox => inbox.greeting_message?.trim());
  greetingMessage.value = firstWithMessage?.greeting_message || '';
};

watch(
  () => inboxes.value,
  list => {
    if (!isSaving.value) {
      hydrateFromInboxes(list);
    }
  },
  { immediate: true, deep: true }
);

const toggleInbox = inboxId => {
  if (props.disabled || isSaving.value) return;
  if (selectedInboxIds.value.includes(inboxId)) {
    selectedInboxIds.value = selectedInboxIds.value.filter(
      id => id !== inboxId
    );
  } else {
    selectedInboxIds.value = [...selectedInboxIds.value, inboxId];
  }
};

const selectAllTextInboxes = () => {
  if (props.disabled || isSaving.value) return;
  selectedInboxIds.value = textInboxes.value.map(inbox => inbox.id);
};

const clearAllTextInboxes = () => {
  if (props.disabled || isSaving.value) return;
  selectedInboxIds.value = [];
};

const handleEnableToggle = () => {
  if (greetingEnabled.value && selectedInboxIds.value.length === 0) {
    selectedInboxIds.value = textInboxes.value.map(inbox => inbox.id);
  }
};

const saveGreetingSettings = async () => {
  if (props.disabled || isSaving.value) return;

  isSaving.value = true;
  try {
    const trimmedMessage = greetingMessage.value.trim();
    const selectedSet = new Set(selectedInboxIds.value);
    const allInboxes = inboxes.value || [];

    const updates = allInboxes
      .map(inbox => {
        const isEligible = !EXCLUDED_CHANNEL_TYPES.includes(inbox.channel_type);
        const shouldEnable =
          isEligible &&
          greetingEnabled.value &&
          selectedSet.has(inbox.id) &&
          trimmedMessage.length > 0;
        const nextMessage = isEligible
          ? trimmedMessage
          : inbox.greeting_message || '';

        const enabledChanged = Boolean(inbox.greeting_enabled) !== shouldEnable;
        const messageChanged =
          isEligible && (inbox.greeting_message || '') !== nextMessage;

        if (!enabledChanged && !messageChanged) return null;

        return store.dispatch('inboxes/updateInbox', {
          id: inbox.id,
          formData: false,
          greeting_enabled: shouldEnable,
          greeting_message: nextMessage,
        });
      })
      .filter(Boolean);

    await Promise.all(updates);
    useAlert(t('GENERAL_SETTINGS.CONVERSATIONS.GREETING_UPDATE_SUCCESS'));
  } catch {
    useAlert(t('GENERAL_SETTINGS.CONVERSATIONS.GREETING_UPDATE_ERROR'));
  } finally {
    isSaving.value = false;
  }
};
</script>

<template>
  <SectionLayout
    :title="t('GENERAL_SETTINGS.CONVERSATIONS.GREETING_TITLE')"
    :description="t('GENERAL_SETTINGS.CONVERSATIONS.GREETING_DESCRIPTION')"
    with-border
  >
    <div class="flex flex-col gap-4" data-test="workspace-greeting-settings">
      <label class="flex items-center gap-3 text-sm text-n-slate-12">
        <input
          v-model="greetingEnabled"
          data-test="workspace-greeting-enabled"
          type="checkbox"
          :disabled="disabled || isSaving"
          @change="handleEnableToggle"
        />
        {{ t('GENERAL_SETTINGS.CONVERSATIONS.GREETING_ENABLED_LABEL') }}
      </label>

      <div v-if="greetingEnabled" class="flex flex-col gap-4">
        <label class="flex flex-col gap-2 text-sm font-medium text-n-slate-12">
          {{ t('GENERAL_SETTINGS.CONVERSATIONS.GREETING_MESSAGE_LABEL') }}
          <textarea
            v-model="greetingMessage"
            data-test="workspace-greeting-message"
            rows="3"
            class="w-full rounded-lg border border-n-weak bg-n-surface-1 px-3 py-2 text-sm text-n-slate-12 focus:border-n-brand focus:outline-none"
            :placeholder="
              t('GENERAL_SETTINGS.CONVERSATIONS.GREETING_MESSAGE_PLACEHOLDER')
            "
            :disabled="disabled || isSaving"
          />
        </label>

        <div class="flex flex-col gap-2">
          <div class="flex flex-wrap items-center justify-between gap-2">
            <span class="text-sm font-medium text-n-slate-12">
              {{ t('GENERAL_SETTINGS.CONVERSATIONS.GREETING_CHANNELS_LABEL') }}
            </span>
            <div class="flex items-center gap-2">
              <button
                type="button"
                class="text-xs font-medium text-n-brand hover:underline"
                :disabled="disabled || isSaving"
                @click="selectAllTextInboxes"
              >
                {{ t('GENERAL_SETTINGS.CONVERSATIONS.SELECT_ALL_CHANNELS') }}
              </button>
              <span class="text-xs text-n-slate-9">·</span>
              <button
                type="button"
                class="text-xs font-medium text-n-slate-11 hover:underline"
                :disabled="disabled || isSaving"
                @click="clearAllTextInboxes"
              >
                {{ t('GENERAL_SETTINGS.CONVERSATIONS.CLEAR_ALL_CHANNELS') }}
              </button>
            </div>
          </div>

          <p
            v-if="!textInboxes.length"
            class="m-0 text-sm text-n-slate-11"
          >
            {{ t('GENERAL_SETTINGS.CONVERSATIONS.NO_TEXT_CHANNELS') }}
          </p>

          <div
            v-else
            class="grid grid-cols-1 gap-2 sm:grid-cols-2 rounded-xl border border-n-weak p-3"
          >
            <label
              v-for="inbox in textInboxes"
              :key="inbox.id"
              class="flex items-center justify-between gap-2 rounded-lg px-2 py-1.5 text-sm text-n-slate-12 hover:bg-n-alpha-1"
            >
              <span class="flex items-center gap-2 min-w-0">
                <input
                  type="checkbox"
                  :checked="selectedInboxIds.includes(inbox.id)"
                  :disabled="disabled || isSaving"
                  @change="toggleInbox(inbox.id)"
                />
                <span class="truncate">{{ inbox.name }}</span>
              </span>
              <span
                v-if="inbox.captain_assistant?.name"
                class="shrink-0 rounded-md bg-n-amber-3 px-2 py-0.5 text-xs text-n-amber-11"
                :title="
                  t('GENERAL_SETTINGS.CONVERSATIONS.GREETING_AI_SKIP_HINT')
                "
              >
                {{
                  t('GENERAL_SETTINGS.CONVERSATIONS.GREETING_AI_BADGE', {
                    name: inbox.captain_assistant.name,
                  })
                }}
              </span>
            </label>
          </div>

          <p class="m-0 text-xs text-n-slate-11">
            {{ t('GENERAL_SETTINGS.CONVERSATIONS.GREETING_AI_SKIP_HINT') }}
          </p>
        </div>
      </div>

      <div v-if="!disabled" class="flex justify-end">
        <Button
          data-test="workspace-greeting-save"
          :label="t('GENERAL_SETTINGS.CONVERSATIONS.GREETING_SAVE')"
          :disabled="isSaving"
          :is-loading="isSaving"
          @click="saveGreetingSettings"
        />
      </div>
    </div>
  </SectionLayout>
</template>
