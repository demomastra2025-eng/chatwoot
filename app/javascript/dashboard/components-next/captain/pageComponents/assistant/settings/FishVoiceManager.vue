<script setup>
import { computed, onBeforeUnmount, onMounted, reactive, ref } from 'vue';
import { useI18n } from 'vue-i18n';

import fishVoicesAPI from 'dashboard/api/captain/fishVoices';
import { useAlert } from 'dashboard/composables';
import Button from 'dashboard/components-next/button/Button.vue';
import Checkbox from 'dashboard/components-next/checkbox/Checkbox.vue';
import Dialog from 'dashboard/components-next/dialog/Dialog.vue';
import Input from 'dashboard/components-next/input/Input.vue';
import Select from 'dashboard/components-next/select/Select.vue';

const props = defineProps({
  modelValue: {
    type: String,
    default: '',
  },
  error: {
    type: String,
    default: '',
  },
});

const emit = defineEmits(['update:modelValue']);
const { t } = useI18n();

const DEFAULT_FISH_VOICE_ID = '31f936a9333f4f5a99dcaaf6df091b84';
const POLL_INTERVAL_MS = 5000;
const TERMINAL_STATES = new Set(['trained', 'failed', 'deleting']);

const voices = ref([]);
const isLoading = ref(false);
const isCreating = ref(false);
const isDeleting = ref(false);
const fileInput = ref(null);
const deleteDialog = ref(null);
const voicePendingDelete = ref(null);
const pendingAutoSelectId = ref(null);
let pollTimer = null;
const deletedVoiceIds = new Set();

const cloneForm = reactive({
  title: '',
  transcript: '',
  voice: null,
  consentConfirmed: false,
});

const managedVoiceOptions = computed(() =>
  voices.value
    .filter(voice => voice.state === 'trained')
    .map(voice => ({
      value: voice.reference_id,
      label: voice.title,
    }))
);

const voiceOptions = computed(() => {
  const options = [
    {
      value: DEFAULT_FISH_VOICE_ID,
      label: t('CAPTAIN.ASSISTANTS.FORM.VOICE_SETTINGS.FISH_VOICES.DEFAULT'),
    },
    ...managedVoiceOptions.value,
  ];

  if (
    props.modelValue &&
    !options.some(option => option.value === props.modelValue)
  ) {
    options.unshift({
      value: props.modelValue,
      label: t('CAPTAIN.ASSISTANTS.FORM.VOICE_SETTINGS.FISH_VOICES.UNKNOWN'),
    });
  }

  return options;
});

const cloneDisabled = computed(
  () =>
    isCreating.value ||
    !cloneForm.title.trim() ||
    !cloneForm.voice ||
    !cloneForm.consentConfirmed
);

const statusLabel = voice => {
  if (voice.state === 'training') {
    return t(
      'CAPTAIN.ASSISTANTS.FORM.VOICE_SETTINGS.FISH_VOICES.STATUS.TRAINING'
    );
  }
  if (voice.state === 'trained') {
    return t(
      'CAPTAIN.ASSISTANTS.FORM.VOICE_SETTINGS.FISH_VOICES.STATUS.TRAINED'
    );
  }
  if (voice.state === 'failed') {
    return t(
      'CAPTAIN.ASSISTANTS.FORM.VOICE_SETTINGS.FISH_VOICES.STATUS.FAILED'
    );
  }
  if (voice.state === 'deleting') {
    return t(
      'CAPTAIN.ASSISTANTS.FORM.VOICE_SETTINGS.FISH_VOICES.STATUS.DELETING'
    );
  }
  return t('CAPTAIN.ASSISTANTS.FORM.VOICE_SETTINGS.FISH_VOICES.STATUS.CREATED');
};

const statusClass = voice => {
  if (voice.state === 'trained') return 'bg-n-teal-3 text-n-teal-11';
  if (voice.state === 'failed') return 'bg-n-ruby-3 text-n-ruby-11';
  return 'bg-n-amber-3 text-n-amber-11';
};

const errorMessage = error => {
  const code = error?.response?.data?.error;
  if (code === 'fish_voice_consent_required') {
    return t(
      'CAPTAIN.ASSISTANTS.FORM.VOICE_SETTINGS.FISH_VOICES.ERROR.FISH_VOICE_CONSENT_REQUIRED'
    );
  }
  if (code === 'fish_voice_audio_too_large') {
    return t(
      'CAPTAIN.ASSISTANTS.FORM.VOICE_SETTINGS.FISH_VOICES.ERROR.FISH_VOICE_AUDIO_TOO_LARGE'
    );
  }
  if (code === 'fish_voice_audio_invalid') {
    return t(
      'CAPTAIN.ASSISTANTS.FORM.VOICE_SETTINGS.FISH_VOICES.ERROR.FISH_VOICE_AUDIO_INVALID'
    );
  }
  if (code === 'fish_voice_in_use') {
    return t(
      'CAPTAIN.ASSISTANTS.FORM.VOICE_SETTINGS.FISH_VOICES.ERROR.FISH_VOICE_IN_USE'
    );
  }
  if (code === 'fish_voice_not_configured') {
    return t(
      'CAPTAIN.ASSISTANTS.FORM.VOICE_SETTINGS.FISH_VOICES.ERROR.FISH_VOICE_NOT_CONFIGURED'
    );
  }
  return t('CAPTAIN.ASSISTANTS.FORM.VOICE_SETTINGS.FISH_VOICES.ERROR.GENERIC');
};

const replaceVoice = updatedVoice => {
  if (deletedVoiceIds.has(updatedVoice.id)) return;

  const index = voices.value.findIndex(voice => voice.id === updatedVoice.id);
  if (index === -1) {
    voices.value.unshift(updatedVoice);
  } else {
    voices.value.splice(index, 1, updatedVoice);
  }

  if (
    pendingAutoSelectId.value === updatedVoice.id &&
    updatedVoice.state === 'trained'
  ) {
    emit('update:modelValue', updatedVoice.reference_id);
    pendingAutoSelectId.value = null;
    useAlert(
      t('CAPTAIN.ASSISTANTS.FORM.VOICE_SETTINGS.FISH_VOICES.CLONE_READY')
    );
  }
};

const refreshPendingVoices = async () => {
  const pendingVoices = voices.value.filter(
    voice => !TERMINAL_STATES.has(voice.state)
  );
  await Promise.all(
    pendingVoices.map(async voice => {
      try {
        const { data } = await fishVoicesAPI.refresh(voice.id);
        replaceVoice(data.payload);
      } catch (error) {
        useAlert(errorMessage(error));
      }
    })
  );
  clearTimeout(pollTimer);
  if (voices.value.some(voice => !TERMINAL_STATES.has(voice.state))) {
    pollTimer = setTimeout(refreshPendingVoices, POLL_INTERVAL_MS);
  }
};

const loadVoices = async ({ refreshPending = true } = {}) => {
  isLoading.value = true;
  try {
    const { data } = await fishVoicesAPI.get();
    voices.value = (data.payload || []).filter(
      voice => !deletedVoiceIds.has(voice.id)
    );
    if (refreshPending) await refreshPendingVoices();
  } catch (error) {
    useAlert(errorMessage(error));
  } finally {
    isLoading.value = false;
  }
};

const handleFileChange = event => {
  [cloneForm.voice] = event.target.files || [];
};

const resetCloneForm = () => {
  cloneForm.title = '';
  cloneForm.transcript = '';
  cloneForm.voice = null;
  cloneForm.consentConfirmed = false;
  if (fileInput.value) fileInput.value.value = '';
};

const createVoice = async () => {
  if (cloneDisabled.value) return;

  isCreating.value = true;
  try {
    const { data } = await fishVoicesAPI.createVoice({
      title: cloneForm.title.trim(),
      voice: cloneForm.voice,
      transcript: cloneForm.transcript.trim(),
      consentConfirmed: cloneForm.consentConfirmed,
    });
    pendingAutoSelectId.value = data.payload.id;
    replaceVoice(data.payload);
    resetCloneForm();
    useAlert(
      t('CAPTAIN.ASSISTANTS.FORM.VOICE_SETTINGS.FISH_VOICES.CLONE_STARTED')
    );
    clearTimeout(pollTimer);
    pollTimer = setTimeout(refreshPendingVoices, POLL_INTERVAL_MS);
  } catch (error) {
    useAlert(errorMessage(error));
  } finally {
    isCreating.value = false;
  }
};

const openDeleteDialog = voice => {
  voicePendingDelete.value = voice;
  deleteDialog.value?.open?.();
};

const deleteVoice = async () => {
  const voice = voicePendingDelete.value;
  if (!voice) return;

  isDeleting.value = true;
  deletedVoiceIds.add(voice.id);
  try {
    await fishVoicesAPI.delete(voice.id);
    voices.value = voices.value.filter(item => item.id !== voice.id);
    if (props.modelValue === voice.reference_id) {
      emit('update:modelValue', DEFAULT_FISH_VOICE_ID);
    }
    if (pendingAutoSelectId.value === voice.id) {
      pendingAutoSelectId.value = null;
    }
    voicePendingDelete.value = null;
    deleteDialog.value?.close?.();
    useAlert(
      t('CAPTAIN.ASSISTANTS.FORM.VOICE_SETTINGS.FISH_VOICES.DELETE_SUCCESS')
    );
  } catch (error) {
    deletedVoiceIds.delete(voice.id);
    useAlert(errorMessage(error));
  } finally {
    isDeleting.value = false;
  }
};

onMounted(loadVoices);
onBeforeUnmount(() => clearTimeout(pollTimer));

defineExpose({
  cloneForm,
  createVoice,
  deleteVoice,
  loadVoices,
  openDeleteDialog,
  refreshPendingVoices,
  voices,
});
</script>

<template>
  <div
    data-test-id="assistant-fish-voice-manager"
    class="md:col-span-2 flex flex-col gap-4 rounded-lg border border-n-weak bg-n-alpha-1 p-4"
  >
    <div class="flex flex-col gap-1.5">
      <div class="flex items-center justify-between gap-3">
        <label class="text-sm font-medium text-n-slate-12">
          {{ t('CAPTAIN.ASSISTANTS.FORM.VOICE_SETTINGS.VOICE') }}
        </label>
        <Button
          type="button"
          icon="i-lucide-refresh-cw"
          slate
          ghost
          xs
          :is-loading="isLoading"
          :label="
            t('CAPTAIN.ASSISTANTS.FORM.VOICE_SETTINGS.FISH_VOICES.REFRESH')
          "
          @click="loadVoices"
        />
      </div>
      <Select
        :model-value="modelValue"
        :options="voiceOptions"
        :disabled="isLoading"
        class="w-full"
        @update:model-value="emit('update:modelValue', $event)"
      />
      <p
        class="m-0 text-sm"
        :class="error ? 'text-n-ruby-11' : 'text-n-slate-11'"
      >
        {{
          error ||
          t(
            'CAPTAIN.ASSISTANTS.FORM.VOICE_SETTINGS.FISH_VOICES.SELECT_DESCRIPTION'
          )
        }}
      </p>
    </div>

    <div v-if="voices.length" class="flex flex-col gap-2">
      <div
        v-for="voice in voices"
        :key="voice.id"
        class="flex items-center justify-between gap-3 rounded-lg border border-n-weak px-3 py-2"
      >
        <div class="min-w-0">
          <p class="m-0 truncate text-sm font-medium text-n-slate-12">
            {{ voice.title }}
          </p>
          <div class="mt-1 flex items-center gap-2">
            <span
              class="rounded-full px-2 py-0.5 text-xs font-medium"
              :class="statusClass(voice)"
            >
              {{ statusLabel(voice) }}
            </span>
            <span v-if="voice.in_use" class="text-xs text-n-slate-10">
              {{
                t('CAPTAIN.ASSISTANTS.FORM.VOICE_SETTINGS.FISH_VOICES.IN_USE', {
                  count: voice.selected_assistants_count,
                })
              }}
            </span>
          </div>
        </div>
        <Button
          type="button"
          icon="i-lucide-trash-2"
          ruby
          ghost
          xs
          :disabled="voice.in_use"
          :aria-label="
            t('CAPTAIN.ASSISTANTS.FORM.VOICE_SETTINGS.FISH_VOICES.DELETE')
          "
          @click="openDeleteDialog(voice)"
        />
      </div>
    </div>

    <details class="rounded-lg border border-n-weak bg-n-solid-1 p-3">
      <summary class="cursor-pointer text-sm font-medium text-n-slate-12">
        {{
          t('CAPTAIN.ASSISTANTS.FORM.VOICE_SETTINGS.FISH_VOICES.CLONE_TITLE')
        }}
      </summary>
      <div class="mt-4 flex flex-col gap-3">
        <p class="m-0 text-sm text-n-slate-11">
          {{
            t(
              'CAPTAIN.ASSISTANTS.FORM.VOICE_SETTINGS.FISH_VOICES.CLONE_SCOPE_DESCRIPTION'
            )
          }}
        </p>
        <Input
          v-model="cloneForm.title"
          :label="t('CAPTAIN.ASSISTANTS.FORM.VOICE_SETTINGS.FISH_VOICES.NAME')"
          :placeholder="
            t(
              'CAPTAIN.ASSISTANTS.FORM.VOICE_SETTINGS.FISH_VOICES.NAME_PLACEHOLDER'
            )
          "
          maxlength="100"
        />
        <Input
          v-model="cloneForm.transcript"
          :label="
            t('CAPTAIN.ASSISTANTS.FORM.VOICE_SETTINGS.FISH_VOICES.TRANSCRIPT')
          "
          :placeholder="
            t(
              'CAPTAIN.ASSISTANTS.FORM.VOICE_SETTINGS.FISH_VOICES.TRANSCRIPT_PLACEHOLDER'
            )
          "
        />
        <label
          class="flex flex-col gap-1.5 text-sm font-medium text-n-slate-12"
        >
          {{ t('CAPTAIN.ASSISTANTS.FORM.VOICE_SETTINGS.FISH_VOICES.AUDIO') }}
          <input
            ref="fileInput"
            data-test-id="fish-voice-audio-input"
            type="file"
            accept=".wav,.mp3,.m4a,.ogg,.opus,audio/*"
            class="block w-full rounded-lg border border-n-strong bg-n-solid-1 px-3 py-2 text-sm text-n-slate-11 file:mr-3 file:rounded-md file:border-0 file:bg-n-alpha-2 file:px-3 file:py-1.5 file:text-sm file:text-n-slate-12"
            @change="handleFileChange"
          />
          <span class="text-xs font-normal text-n-slate-10">
            {{
              t('CAPTAIN.ASSISTANTS.FORM.VOICE_SETTINGS.FISH_VOICES.AUDIO_HINT')
            }}
          </span>
        </label>
        <label class="flex items-start gap-2 text-sm text-n-slate-11">
          <Checkbox
            v-model="cloneForm.consentConfirmed"
            class="mt-0.5 shrink-0"
          />
          <span>
            {{
              t('CAPTAIN.ASSISTANTS.FORM.VOICE_SETTINGS.FISH_VOICES.CONSENT')
            }}
          </span>
        </label>
        <Button
          type="button"
          class="self-start"
          icon="i-lucide-audio-lines"
          :label="t('CAPTAIN.ASSISTANTS.FORM.VOICE_SETTINGS.FISH_VOICES.CLONE')"
          :is-loading="isCreating"
          :disabled="cloneDisabled"
          @click="createVoice"
        />
      </div>
    </details>

    <Dialog
      ref="deleteDialog"
      type="alert"
      :title="
        t('CAPTAIN.ASSISTANTS.FORM.VOICE_SETTINGS.FISH_VOICES.DELETE_TITLE')
      "
      :description="
        t(
          'CAPTAIN.ASSISTANTS.FORM.VOICE_SETTINGS.FISH_VOICES.DELETE_DESCRIPTION',
          { title: voicePendingDelete?.title || '' }
        )
      "
      :confirm-button-label="
        t('CAPTAIN.ASSISTANTS.FORM.VOICE_SETTINGS.FISH_VOICES.DELETE')
      "
      :is-loading="isDeleting"
      @confirm="deleteVoice"
    />
  </div>
</template>
