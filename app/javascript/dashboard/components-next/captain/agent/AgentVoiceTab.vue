<script setup>
import { defineAsyncComponent, ref, watch } from 'vue';
import { useI18n } from 'vue-i18n';
import { useStore } from 'dashboard/composables/store';
import { useAlert } from 'dashboard/composables';
import CaptainAssistantAPI from 'dashboard/api/captain/assistant';
import Button from 'dashboard/components-next/button/Button.vue';
import AssistantSystemSettingsForm from 'dashboard/components-next/captain/pageComponents/assistant/settings/AssistantSystemSettingsForm.vue';

const props = defineProps({
  assistant: { type: Object, required: true },
  canEdit: { type: Boolean, default: false },
});

const emit = defineEmits(['dirtyChange', 'saved']);

// The preview opens a microphone session; load it only with this tab.
const VoiceAgentPreview = defineAsyncComponent(
  () =>
    import(
      'dashboard/components-next/captain/pageComponents/assistant/settings/VoiceAgentPreview.vue'
    )
);

const { t } = useI18n();
const store = useStore();

const formRef = ref(null);
const isDirty = ref(false);
const isSaving = ref(false);

const setDirty = value => {
  if (isDirty.value === value) return;
  isDirty.value = value;
  emit('dirtyChange', value);
};

// The voice form keeps its draft to itself and emits nothing while it is
// edited, so a change is detected from the native events of its controls:
// inputs, selects and text editors fire input/change, switches are buttons.
const markDirty = event => {
  if (!props.canEdit) return;
  if (event.type === 'click' && !event.target?.closest?.('[role="switch"]')) {
    return;
  }
  setDirty(true);
};

watch(
  () => props.assistant?.id,
  () => setDirty(false)
);

const save = async () => {
  if (!props.canEdit || isSaving.value) return false;

  const payload = await formRef.value?.buildPayload?.();
  const voiceSettings = payload?.assistant?.config?.voice_settings;
  if (!voiceSettings) return false;

  const assistantId = props.assistant.id;
  isSaving.value = true;
  try {
    const response = await CaptainAssistantAPI.update(assistantId, {
      config: { voice_settings: voiceSettings },
    });
    setDirty(false);
    let refreshed = null;
    try {
      refreshed = await store.dispatch('captainAssistants/show', assistantId);
    } catch {
      // The change is saved; the next load brings the fresh record.
    }
    emit('saved', refreshed || response?.data || props.assistant);
    useAlert(t('CAPTAIN.ASSISTANTS.EDIT.SUCCESS_MESSAGE'));
    return true;
  } catch {
    useAlert(t('CAPTAIN.ASSISTANTS.EDIT.ERROR_MESSAGE'));
    return false;
  } finally {
    isSaving.value = false;
  }
};

defineExpose({ isDirty, save });
</script>

<template>
  <div class="flex w-full flex-col gap-6" data-testid="agent-voice-tab">
    <div class="flex flex-col gap-1">
      <h3 class="mb-0 text-heading-2 text-n-slate-12">
        {{ t('CAPTAIN.AGENT_TABS.VOICE.TITLE') }}
      </h3>
      <p class="mb-0 text-body-main text-n-slate-11">
        {{ t('CAPTAIN.AGENT_TABS.VOICE.DESCRIPTION') }}
      </p>
    </div>

    <VoiceAgentPreview
      v-if="assistant?.id"
      :assistant-id="assistant.id"
      :configured-provider="
        assistant.config?.voice_settings?.provider || 'gemini-live'
      "
    />

    <div
      :inert="!canEdit"
      data-testid="agent-voice-form"
      @input="markDirty"
      @change="markDirty"
      @click="markDirty"
    >
      <AssistantSystemSettingsForm
        ref="formRef"
        :assistant="assistant"
        :show-conversation-messages="false"
        show-voice-settings
        :show-submit-button="false"
      />
    </div>

    <div v-if="canEdit" class="flex justify-end">
      <Button
        :label="t('CAPTAIN.AGENT_TABS.VOICE.SAVE')"
        :is-loading="isSaving"
        :disabled="isSaving"
        data-testid="agent-voice-save"
        @click="save"
      />
    </div>
  </div>
</template>
