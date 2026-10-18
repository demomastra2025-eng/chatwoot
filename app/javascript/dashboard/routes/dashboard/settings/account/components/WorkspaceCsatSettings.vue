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

const textInboxes = computed(() =>
  (inboxes.value || []).filter(
    inbox => inbox.channel_type !== INBOX_TYPES.VOICE
  )
);

const csatEnabled = ref(false);
const displayType = ref('emoji');
const csatMessage = ref('');
const selectedInboxIds = ref([]);
const isSaving = ref(false);

const hydrateFromInboxes = list => {
  const eligible = (list || []).filter(
    inbox => inbox.channel_type !== INBOX_TYPES.VOICE
  );
  const enabledInboxes = eligible.filter(inbox => inbox.csat_survey_enabled);
  csatEnabled.value = enabledInboxes.length > 0;
  selectedInboxIds.value = enabledInboxes.map(inbox => inbox.id);

  const sourceInbox =
    enabledInboxes.find(inbox => inbox.csat_config?.message?.trim()) ||
    enabledInboxes[0] ||
    eligible.find(inbox => inbox.csat_config?.message?.trim()) ||
    eligible[0];

  displayType.value = sourceInbox?.csat_config?.display_type || 'emoji';
  csatMessage.value = sourceInbox?.csat_config?.message || '';
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
  if (csatEnabled.value && selectedInboxIds.value.length === 0) {
    selectedInboxIds.value = textInboxes.value.map(inbox => inbox.id);
  }
};

const saveCsatSettings = async () => {
  if (props.disabled || isSaving.value) return;

  isSaving.value = true;
  try {
    const trimmedMessage = csatMessage.value.trim();
    const selectedSet = new Set(selectedInboxIds.value);
    const allInboxes = inboxes.value || [];

    const updates = allInboxes
      .map(inbox => {
        const isEligible = inbox.channel_type !== INBOX_TYPES.VOICE;
        const shouldEnable =
          isEligible && csatEnabled.value && selectedSet.has(inbox.id);
        const currentConfig = inbox.csat_config || {};
        const nextConfig = isEligible
          ? {
              ...currentConfig,
              display_type: displayType.value,
              message: trimmedMessage,
            }
          : currentConfig;

        const enabledChanged =
          Boolean(inbox.csat_survey_enabled) !== shouldEnable;
        const configChanged =
          isEligible &&
          ((currentConfig.display_type || 'emoji') !== displayType.value ||
            (currentConfig.message || '') !== trimmedMessage);

        if (!enabledChanged && !configChanged) return null;

        return store.dispatch('inboxes/updateInbox', {
          id: inbox.id,
          formData: false,
          csat_survey_enabled: shouldEnable,
          csat_config: nextConfig,
        });
      })
      .filter(Boolean);

    await Promise.all(updates);
    useAlert(t('GENERAL_SETTINGS.CONVERSATIONS.CSAT_UPDATE_SUCCESS'));
  } catch {
    useAlert(t('GENERAL_SETTINGS.CONVERSATIONS.CSAT_UPDATE_ERROR'));
  } finally {
    isSaving.value = false;
  }
};
</script>

<template>
  <SectionLayout
    :title="t('GENERAL_SETTINGS.CONVERSATIONS.CSAT_TITLE')"
    :description="t('GENERAL_SETTINGS.CONVERSATIONS.CSAT_DESCRIPTION')"
    with-border
  >
    <div class="flex flex-col gap-4" data-test="workspace-csat-settings">
      <label class="flex items-center gap-3 text-sm text-n-slate-12">
        <input
          v-model="csatEnabled"
          data-test="workspace-csat-enabled"
          type="checkbox"
          :disabled="disabled || isSaving"
          @change="handleEnableToggle"
        />
        {{ t('GENERAL_SETTINGS.CONVERSATIONS.CSAT_ENABLED_LABEL') }}
      </label>

      <div v-if="csatEnabled" class="flex flex-col gap-4">
        <label class="flex flex-col gap-2 text-sm font-medium text-n-slate-12">
          {{ t('GENERAL_SETTINGS.CONVERSATIONS.CSAT_DISPLAY_TYPE_LABEL') }}
          <select
            v-model="displayType"
            data-test="workspace-csat-display-type"
            class="w-full max-w-xs rounded-lg border border-n-weak bg-n-surface-1 px-3 py-2 text-sm text-n-slate-12 focus:border-n-brand focus:outline-none"
            :disabled="disabled || isSaving"
          >
            <option value="emoji">
              {{ t('GENERAL_SETTINGS.CONVERSATIONS.CSAT_DISPLAY_EMOJI') }}
            </option>
            <option value="star">
              {{ t('GENERAL_SETTINGS.CONVERSATIONS.CSAT_DISPLAY_STAR') }}
            </option>
          </select>
        </label>

        <label class="flex flex-col gap-2 text-sm font-medium text-n-slate-12">
          {{ t('GENERAL_SETTINGS.CONVERSATIONS.CSAT_MESSAGE_LABEL') }}
          <textarea
            v-model="csatMessage"
            data-test="workspace-csat-message"
            rows="3"
            class="w-full rounded-lg border border-n-weak bg-n-surface-1 px-3 py-2 text-sm text-n-slate-12 focus:border-n-brand focus:outline-none"
            :placeholder="
              t('GENERAL_SETTINGS.CONVERSATIONS.CSAT_MESSAGE_PLACEHOLDER')
            "
            :disabled="disabled || isSaving"
          />
        </label>

        <div class="flex flex-col gap-2">
          <div class="flex flex-wrap items-center justify-between gap-2">
            <span class="text-sm font-medium text-n-slate-12">
              {{ t('GENERAL_SETTINGS.CONVERSATIONS.CSAT_CHANNELS_LABEL') }}
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
              class="flex items-center gap-2 rounded-lg px-2 py-1.5 text-sm text-n-slate-12 hover:bg-n-alpha-1"
            >
              <input
                type="checkbox"
                :checked="selectedInboxIds.includes(inbox.id)"
                :disabled="disabled || isSaving"
                @change="toggleInbox(inbox.id)"
              />
              <span class="truncate">{{ inbox.name }}</span>
            </label>
          </div>
        </div>
      </div>

      <div v-if="!disabled" class="flex justify-end">
        <Button
          data-test="workspace-csat-save"
          :label="t('GENERAL_SETTINGS.CONVERSATIONS.CSAT_SAVE')"
          :disabled="isSaving"
          :is-loading="isSaving"
          @click="saveCsatSettings"
        />
      </div>
    </div>
  </SectionLayout>
</template>
