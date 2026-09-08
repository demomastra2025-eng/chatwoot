<script setup>
import { computed, ref } from 'vue';
import { useI18n } from 'vue-i18n';
import { useAccount } from 'dashboard/composables/useAccount';
import { useAlert } from 'dashboard/composables';
import Switch from 'dashboard/components-next/switch/Switch.vue';
import SectionLayout from './SectionLayout.vue';

defineProps({
  disabled: {
    type: Boolean,
    default: false,
  },
});

const { t } = useI18n();
const { currentAccount, updateAccount } = useAccount();
const updatingKey = ref(null);

const settings = computed(() => currentAccount.value?.settings || {});
const audioTranscriptionsEnabled = computed(
  () => settings.value.audio_transcriptions === true
);
const callTranscriptionsEnabled = computed(() => {
  const callSetting = settings.value.call_transcriptions;
  return callSetting === null || callSetting === undefined
    ? audioTranscriptionsEnabled.value
    : callSetting === true;
});

const updateTranscriptionSetting = async (key, enabled) => {
  try {
    updatingKey.value = key;
    await updateAccount({ [key]: enabled }, { silent: true });
    useAlert(t('GENERAL_SETTINGS.FORM.MEDIA_TRANSCRIPTION.API.SUCCESS'));
  } catch {
    useAlert(t('GENERAL_SETTINGS.FORM.MEDIA_TRANSCRIPTION.API.ERROR'));
  } finally {
    updatingKey.value = null;
  }
};
</script>

<template>
  <SectionLayout
    :title="t('GENERAL_SETTINGS.FORM.MEDIA_TRANSCRIPTION.TITLE')"
    :description="t('GENERAL_SETTINGS.FORM.MEDIA_TRANSCRIPTION.NOTE')"
  >
    <div
      class="divide-y divide-n-weak rounded-xl border border-n-weak bg-n-solid-1"
    >
      <div class="flex items-start justify-between gap-4 p-4">
        <div class="min-w-0">
          <p class="mb-1 text-sm font-medium text-n-slate-12">
            {{ t('GENERAL_SETTINGS.FORM.MEDIA_TRANSCRIPTION.AUDIO.TITLE') }}
          </p>
          <p class="mb-0 text-sm text-n-slate-11">
            {{ t('GENERAL_SETTINGS.FORM.MEDIA_TRANSCRIPTION.AUDIO.NOTE') }}
          </p>
        </div>
        <Switch
          :model-value="audioTranscriptionsEnabled"
          :disabled="disabled || updatingKey !== null"
          @change="
            enabled =>
              updateTranscriptionSetting('audio_transcriptions', enabled)
          "
        />
      </div>

      <div class="flex items-start justify-between gap-4 p-4">
        <div class="min-w-0">
          <p class="mb-1 text-sm font-medium text-n-slate-12">
            {{ t('GENERAL_SETTINGS.FORM.MEDIA_TRANSCRIPTION.CALLS.TITLE') }}
          </p>
          <p class="mb-0 text-sm text-n-slate-11">
            {{ t('GENERAL_SETTINGS.FORM.MEDIA_TRANSCRIPTION.CALLS.NOTE') }}
          </p>
        </div>
        <Switch
          :model-value="callTranscriptionsEnabled"
          :disabled="disabled || updatingKey !== null"
          @change="
            enabled =>
              updateTranscriptionSetting('call_transcriptions', enabled)
          "
        />
      </div>
    </div>
  </SectionLayout>
</template>
