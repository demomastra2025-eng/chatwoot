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
    with-border
  >
    <div
      class="divide-y divide-n-weak rounded-xl outline outline-1 -outline-offset-1 outline-n-weak"
    >
      <div class="flex flex-col gap-1 px-4 py-3">
        <div class="flex items-center justify-between gap-3">
          <span class="min-w-0 text-heading-3 text-n-slate-12">
            {{ t('GENERAL_SETTINGS.FORM.MEDIA_TRANSCRIPTION.AUDIO.TITLE') }}
          </span>
          <Switch
            :model-value="audioTranscriptionsEnabled"
            :disabled="disabled || updatingKey !== null"
            @change="
              enabled =>
                updateTranscriptionSetting('audio_transcriptions', enabled)
            "
          />
        </div>
        <p class="mb-0 text-body-main text-n-slate-11">
          {{ t('GENERAL_SETTINGS.FORM.MEDIA_TRANSCRIPTION.AUDIO.NOTE') }}
        </p>
      </div>

      <div class="flex flex-col gap-1 px-4 py-3">
        <div class="flex items-center justify-between gap-3">
          <span class="min-w-0 text-heading-3 text-n-slate-12">
            {{ t('GENERAL_SETTINGS.FORM.MEDIA_TRANSCRIPTION.CALLS.TITLE') }}
          </span>
          <Switch
            :model-value="callTranscriptionsEnabled"
            :disabled="disabled || updatingKey !== null"
            @change="
              enabled =>
                updateTranscriptionSetting('call_transcriptions', enabled)
            "
          />
        </div>
        <p class="mb-0 text-body-main text-n-slate-11">
          {{ t('GENERAL_SETTINGS.FORM.MEDIA_TRANSCRIPTION.CALLS.NOTE') }}
        </p>
      </div>
    </div>
  </SectionLayout>
</template>
