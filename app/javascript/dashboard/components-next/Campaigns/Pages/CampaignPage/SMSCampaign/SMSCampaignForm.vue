<script setup>
import { reactive, computed, ref, onMounted, onBeforeUnmount } from 'vue';
import { useI18n } from 'vue-i18n';
import { useVuelidate } from '@vuelidate/core';
import { required, minLength } from '@vuelidate/validators';
import { useMapGetter, useStore } from 'dashboard/composables/store';
import { useAlert } from 'dashboard/composables';

import Input from 'dashboard/components-next/input/Input.vue';
import TextArea from 'dashboard/components-next/textarea/TextArea.vue';
import Button from 'dashboard/components-next/button/Button.vue';
import ComboBox from 'dashboard/components-next/combobox/ComboBox.vue';
import TagMultiSelectComboBox from 'dashboard/components-next/combobox/TagMultiSelectComboBox.vue';
import CampaignPreviewSummary from 'dashboard/components-next/Campaigns/Pages/CampaignPage/CampaignPreviewSummary.vue';

const emit = defineEmits(['submit', 'cancel']);

const { t } = useI18n();
const store = useStore();

const formState = {
  uiFlags: useMapGetter('campaigns/getUIFlags'),
  labels: useMapGetter('labels/getLabels'),
  inboxes: useMapGetter('inboxes/getSMSInboxes'),
};

const initialState = {
  title: '',
  message: '',
  inboxId: null,
  scheduledAt: null,
  selectedAudience: [],
};

const state = reactive({ ...initialState });
const lastPreviewSignature = ref(null);

const rules = {
  title: { required, minLength: minLength(1) },
  message: { required, minLength: minLength(1) },
  inboxId: { required },
  scheduledAt: { required },
  selectedAudience: { required },
};

const v$ = useVuelidate(rules, state);

const isCreating = computed(() => formState.uiFlags.value.isCreating);
const isPreviewing = computed(() => formState.uiFlags.value.isPreviewing);
const preview = computed(() => store.getters['campaigns/getPreview']);

const currentDateTime = computed(() => {
  // Added to disable the scheduled at field from being set to the current time
  const now = new Date();
  const localTime = new Date(now.getTime() - now.getTimezoneOffset() * 60000);
  return localTime.toISOString().slice(0, 16);
});

const mapToOptions = (items, valueKey, labelKey) =>
  items?.map(item => ({
    value: item[valueKey],
    label: item[labelKey],
  })) ?? [];

const audienceList = computed(() =>
  mapToOptions(formState.labels.value, 'id', 'title')
);

const inboxOptions = computed(() =>
  mapToOptions(formState.inboxes.value, 'id', 'name')
);

const getErrorMessage = (field, errorKey) => {
  const baseKey = 'CAMPAIGN.SMS.CREATE.FORM';
  return v$.value[field].$error ? t(`${baseKey}.${errorKey}.ERROR`) : '';
};

const formErrors = computed(() => ({
  title: getErrorMessage('title', 'TITLE'),
  message: getErrorMessage('message', 'MESSAGE'),
  inbox: getErrorMessage('inboxId', 'INBOX'),
  scheduledAt: getErrorMessage('scheduledAt', 'SCHEDULED_AT'),
  audience: getErrorMessage('selectedAudience', 'AUDIENCE'),
}));

const formatToUTCString = localDateTime =>
  localDateTime ? new Date(localDateTime).toISOString() : null;

const previewPayload = computed(() => ({
  title: state.title,
  message: state.message,
  inbox_id: state.inboxId,
  scheduled_at: formatToUTCString(state.scheduledAt),
  audience: state.selectedAudience?.map(id => ({
    id,
    type: 'Label',
  })),
}));

const previewSignature = computed(() => JSON.stringify(previewPayload.value));

const isPreviewStale = computed(() => {
  if (!preview.value || !lastPreviewSignature.value) return false;
  return lastPreviewSignature.value !== previewSignature.value;
});

const canSubmit = computed(
  () =>
    !v$.value.$invalid &&
    !!preview.value &&
    !isPreviewStale.value &&
    preview.value.deliverable_count > 0
);

const previewHint = computed(() => {
  if (!preview.value) return t('CAMPAIGN.PREVIEW.EMPTY_MESSAGE');
  if (isPreviewStale.value) return t('CAMPAIGN.PREVIEW.STALE_MESSAGE');
  if (preview.value.deliverable_count === 0) {
    return t('CAMPAIGN.PREVIEW.BLOCKED_MESSAGE');
  }

  return t('CAMPAIGN.PREVIEW.READY_MESSAGE');
});

const clearPreviewState = () => {
  store.dispatch('campaigns/clearPreview');
  lastPreviewSignature.value = null;
};

const resetState = () => {
  Object.assign(state, initialState);
  clearPreviewState();
  v$.value.$reset();
};

const handleCancel = () => {
  clearPreviewState();
  emit('cancel');
};

const prepareCampaignDetails = () => previewPayload.value;

const handlePreview = async () => {
  const isFormValid = await v$.value.$validate();
  if (!isFormValid) return;

  try {
    await store.dispatch('campaigns/preview', prepareCampaignDetails());
    lastPreviewSignature.value = previewSignature.value;
  } catch {
    lastPreviewSignature.value = null;
    useAlert(t('CAMPAIGN.PREVIEW.ERROR_MESSAGE'));
  }
};

const handleSubmit = async () => {
  const isFormValid = await v$.value.$validate();
  if (!isFormValid) return;
  if (
    !preview.value ||
    isPreviewStale.value ||
    preview.value.deliverable_count < 1
  ) {
    useAlert(t('CAMPAIGN.PREVIEW.SUBMIT_REQUIRES_PREVIEW'));
    return;
  }

  emit('submit', prepareCampaignDetails());
  resetState();
  handleCancel();
};

onMounted(clearPreviewState);
onBeforeUnmount(clearPreviewState);
</script>

<template>
  <form class="flex flex-col gap-4" @submit.prevent="handleSubmit">
    <Input
      v-model="state.title"
      :label="t('CAMPAIGN.SMS.CREATE.FORM.TITLE.LABEL')"
      :placeholder="t('CAMPAIGN.SMS.CREATE.FORM.TITLE.PLACEHOLDER')"
      :message="formErrors.title"
      :message-type="formErrors.title ? 'error' : 'info'"
    />

    <TextArea
      v-model="state.message"
      :label="t('CAMPAIGN.SMS.CREATE.FORM.MESSAGE.LABEL')"
      :placeholder="t('CAMPAIGN.SMS.CREATE.FORM.MESSAGE.PLACEHOLDER')"
      show-character-count
      :message="formErrors.message"
      :message-type="formErrors.message ? 'error' : 'info'"
    />

    <div class="flex flex-col gap-1">
      <label for="inbox" class="mb-0.5 text-sm font-medium text-n-slate-12">
        {{ t('CAMPAIGN.SMS.CREATE.FORM.INBOX.LABEL') }}
      </label>
      <ComboBox
        id="inbox"
        v-model="state.inboxId"
        :options="inboxOptions"
        :has-error="!!formErrors.inbox"
        :placeholder="t('CAMPAIGN.SMS.CREATE.FORM.INBOX.PLACEHOLDER')"
        :message="formErrors.inbox"
        class="[&>div>button]:bg-n-alpha-black2 [&>div>button:not(.focused)]:dark:outline-n-weak [&>div>button:not(.focused)]:hover:!outline-n-slate-6"
      />
    </div>

    <div class="flex flex-col gap-1">
      <label for="audience" class="mb-0.5 text-sm font-medium text-n-slate-12">
        {{ t('CAMPAIGN.SMS.CREATE.FORM.AUDIENCE.LABEL') }}
      </label>
      <TagMultiSelectComboBox
        v-model="state.selectedAudience"
        :options="audienceList"
        :label="t('CAMPAIGN.SMS.CREATE.FORM.AUDIENCE.LABEL')"
        :placeholder="t('CAMPAIGN.SMS.CREATE.FORM.AUDIENCE.PLACEHOLDER')"
        :has-error="!!formErrors.audience"
        :message="formErrors.audience"
        class="[&>div>button]:bg-n-alpha-black2"
      />
    </div>

    <Input
      v-model="state.scheduledAt"
      :label="t('CAMPAIGN.SMS.CREATE.FORM.SCHEDULED_AT.LABEL')"
      type="datetime-local"
      :min="currentDateTime"
      :placeholder="t('CAMPAIGN.SMS.CREATE.FORM.SCHEDULED_AT.PLACEHOLDER')"
      :message="formErrors.scheduledAt"
      :message-type="formErrors.scheduledAt ? 'error' : 'info'"
    />

    <div class="flex flex-col gap-2">
      <CampaignPreviewSummary :preview="preview" :stale="isPreviewStale" />
      <p class="text-xs text-n-slate-11">
        {{ previewHint }}
      </p>
      <Button
        type="button"
        variant="outline"
        color="slate"
        :label="t('CAMPAIGN.PREVIEW.ACTION')"
        :is-loading="isPreviewing"
        :disabled="isCreating || isPreviewing"
        @click="handlePreview"
      />
    </div>

    <div class="flex items-center justify-between w-full gap-3">
      <Button
        variant="faded"
        color="slate"
        type="button"
        :label="t('CAMPAIGN.SMS.CREATE.FORM.BUTTONS.CANCEL')"
        class="w-full bg-n-alpha-2 text-n-blue-11 hover:bg-n-alpha-3"
        @click="handleCancel"
      />
      <Button
        :label="t('CAMPAIGN.SMS.CREATE.FORM.BUTTONS.CREATE')"
        class="w-full"
        type="submit"
        :is-loading="isCreating"
        :disabled="isCreating || isPreviewing || !canSubmit"
      />
    </div>
  </form>
</template>
