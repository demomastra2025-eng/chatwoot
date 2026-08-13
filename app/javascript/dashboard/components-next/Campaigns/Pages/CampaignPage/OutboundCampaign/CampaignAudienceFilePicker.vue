<script setup>
import { computed, onBeforeUnmount, ref } from 'vue';
import { useI18n } from 'vue-i18n';
import CampaignsAPI from 'dashboard/api/campaigns';
import Button from 'dashboard/components-next/button/Button.vue';
import Input from 'dashboard/components-next/input/Input.vue';

const props = defineProps({
  inboxId: {
    type: [Number, String],
    default: null,
  },
});

const emit = defineEmits(['completed', 'cleared']);
const { t } = useI18n();
const fileInput = ref(null);
const selectedFile = ref(null);
const defaultCountry = ref('KZ');
const audienceImport = ref(null);
const isUploading = ref(false);
const errorCode = ref('');
let pollTimer = null;
let pollGeneration = 0;

const report = computed(() => audienceImport.value || {});
const hasTerminalReport = computed(() =>
  ['completed', 'failed'].includes(report.value.status)
);
const isProcessing = computed(() =>
  Boolean(audienceImport.value && !hasTerminalReport.value)
);
const canUpload = computed(() =>
  Boolean(props.inboxId && selectedFile.value && defaultCountry.value)
);
const errorMessage = computed(() =>
  errorCode.value ? t('CAMPAIGN.OUTBOUND.CREATE.FORM.FILE_AUDIENCE.ERROR') : ''
);
const statLabels = computed(() => ({
  recipients: t('CAMPAIGN.OUTBOUND.CREATE.FORM.FILE_AUDIENCE.RECIPIENTS'),
  created: t('CAMPAIGN.OUTBOUND.CREATE.FORM.FILE_AUDIENCE.CREATED'),
  existing: t('CAMPAIGN.OUTBOUND.CREATE.FORM.FILE_AUDIENCE.EXISTING'),
  duplicates: t('CAMPAIGN.OUTBOUND.CREATE.FORM.FILE_AUDIENCE.DUPLICATES'),
  invalid: t('CAMPAIGN.OUTBOUND.CREATE.FORM.FILE_AUDIENCE.INVALID'),
  conflicts: t('CAMPAIGN.OUTBOUND.CREATE.FORM.FILE_AUDIENCE.CONFLICTS'),
}));
const statLine = (key, value) => `${statLabels.value[key]}: ${value}`;

const resetImport = () => {
  pollGeneration += 1;
  if (pollTimer) window.clearTimeout(pollTimer);
  pollTimer = null;
  isUploading.value = false;
  audienceImport.value = null;
  errorCode.value = '';
  emit('cleared');
};

const selectFile = event => {
  selectedFile.value = event.target.files?.[0] || null;
  resetImport();
};

const pollImport = async (id, generation, attempts = 0) => {
  if (generation !== pollGeneration || attempts >= 120) {
    if (attempts >= 120) {
      errorCode.value = 'processing_timeout';
      audienceImport.value = { ...audienceImport.value, status: 'failed' };
    }
    return;
  }

  try {
    const { data } = await CampaignsAPI.getAudienceImport(id);
    if (generation !== pollGeneration) return;
    audienceImport.value = data;
    if (data.status === 'completed') {
      emit('completed', data);
      return;
    }
    if (data.status === 'failed') {
      errorCode.value = data.processing_error || 'processing_failed';
      return;
    }
  } catch {
    if (generation !== pollGeneration) return;
    errorCode.value = 'poll_failed';
    audienceImport.value = { ...audienceImport.value, status: 'failed' };
    return;
  }

  pollTimer = window.setTimeout(
    () => pollImport(id, generation, attempts + 1),
    1000
  );
};

const upload = async () => {
  if (!canUpload.value || isUploading.value) return;

  resetImport();
  isUploading.value = true;
  const generation = pollGeneration;
  try {
    const { data } = await CampaignsAPI.importAudience({
      file: selectedFile.value,
      inboxId: props.inboxId,
      defaultCountry: defaultCountry.value,
    });
    if (generation !== pollGeneration) return;
    audienceImport.value = data;
    await pollImport(data.id, generation);
  } catch (error) {
    if (generation !== pollGeneration) return;
    errorCode.value = error?.response?.data?.error || 'upload_failed';
  } finally {
    if (generation === pollGeneration) isUploading.value = false;
  }
};

const removeFile = () => {
  selectedFile.value = null;
  if (fileInput.value) fileInput.value.value = '';
  resetImport();
};

onBeforeUnmount(() => {
  pollGeneration += 1;
  if (pollTimer) window.clearTimeout(pollTimer);
});

defineExpose({ resetImport });
</script>

<template>
  <div
    class="grid gap-3 rounded-xl bg-n-alpha-1 p-4 outline outline-1 outline-n-weak"
  >
    <div class="grid gap-1">
      <p class="mb-0 text-sm font-medium text-n-slate-12">
        {{ t('CAMPAIGN.OUTBOUND.CREATE.FORM.FILE_AUDIENCE.TITLE') }}
      </p>
      <p class="mb-0 text-xs leading-5 text-n-slate-11">
        {{ t('CAMPAIGN.OUTBOUND.CREATE.FORM.FILE_AUDIENCE.DESCRIPTION') }}
      </p>
    </div>

    <Input
      v-model="defaultCountry"
      :label="t('CAMPAIGN.OUTBOUND.CREATE.FORM.FILE_AUDIENCE.COUNTRY')"
      placeholder="KZ"
      maxlength="2"
      @update:model-value="resetImport"
    />

    <input
      ref="fileInput"
      type="file"
      accept=".csv,text/csv"
      class="block w-full text-sm text-n-slate-11 file:mr-3 file:rounded-md file:border-0 file:bg-n-alpha-2 file:px-3 file:py-2 file:text-sm file:text-n-slate-12"
      data-test-id="campaign-audience-file"
      @change="selectFile"
    />

    <div class="flex items-center gap-2">
      <Button
        data-test-id="campaign-audience-upload"
        size="sm"
        icon="i-lucide-upload"
        :label="t('CAMPAIGN.OUTBOUND.CREATE.FORM.FILE_AUDIENCE.UPLOAD')"
        :disabled="!canUpload || isUploading || isProcessing"
        :is-loading="isUploading || isProcessing"
        @click="upload"
      />
      <Button
        v-if="selectedFile"
        size="sm"
        color="slate"
        variant="ghost"
        :label="t('CAMPAIGN.OUTBOUND.CREATE.FORM.FILE_AUDIENCE.REMOVE')"
        @click="removeFile"
      />
    </div>

    <div
      v-if="report.status === 'completed'"
      class="grid grid-cols-2 gap-2 rounded-lg bg-n-solid-1 p-3 text-xs text-n-slate-11 md:grid-cols-3"
      data-test-id="campaign-audience-report"
    >
      <span>{{ statLine('recipients', report.recipient_count) }}</span>
      <span>{{ statLine('created', report.created_count) }}</span>
      <span>{{ statLine('existing', report.existing_count) }}</span>
      <span>{{ statLine('duplicates', report.duplicate_count) }}</span>
      <span>{{ statLine('invalid', report.invalid_count) }}</span>
      <span>{{ statLine('conflicts', report.conflict_count) }}</span>
    </div>

    <p
      v-if="errorCode"
      class="mb-0 text-xs text-n-ruby-11"
      data-test-id="campaign-audience-error"
    >
      {{ errorMessage }}
    </p>
  </div>
</template>
