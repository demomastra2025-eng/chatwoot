<script setup>
import {
  reactive,
  computed,
  watch,
  ref,
  onMounted,
  onBeforeUnmount,
} from 'vue';
import { useI18n } from 'vue-i18n';
import { useVuelidate } from '@vuelidate/core';
import { required, minLength } from '@vuelidate/validators';
import { useMapGetter, useStore } from 'dashboard/composables/store';
import { useAlert } from 'dashboard/composables';

import Input from 'dashboard/components-next/input/Input.vue';
import Button from 'dashboard/components-next/button/Button.vue';
import ComboBox from 'dashboard/components-next/combobox/ComboBox.vue';
import TagMultiSelectComboBox from 'dashboard/components-next/combobox/TagMultiSelectComboBox.vue';
import WhatsAppTemplateParser from 'dashboard/components-next/whatsapp/WhatsAppTemplateParser.vue';
import CampaignPreviewSummary from 'dashboard/components-next/Campaigns/Pages/CampaignPage/CampaignPreviewSummary.vue';
import { groupWhatsAppTemplates } from 'dashboard/helper/whatsappTemplateLibrary';

const emit = defineEmits(['submit', 'cancel']);

const { t } = useI18n();
const store = useStore();

const formState = {
  uiFlags: useMapGetter('campaigns/getUIFlags'),
  labels: useMapGetter('labels/getLabels'),
  inboxes: useMapGetter('inboxes/getWhatsAppInboxes'),
  getFilteredWhatsAppTemplates: useMapGetter(
    'inboxes/getFilteredWhatsAppTemplates'
  ),
};

const initialState = {
  title: '',
  inboxId: null,
  templateName: null,
  templateLanguage: null,
  scheduledAt: null,
  selectedAudience: [],
};

const state = reactive({ ...initialState });
const templateParserRef = ref(null);
const lastPreviewSignature = ref(null);

const rules = {
  title: { required, minLength: minLength(1) },
  inboxId: { required },
  templateName: { required },
  templateLanguage: { required },
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

const friendlyTemplateName = templateName =>
  templateName
    .replace(/_/g, ' ')
    .replace(/\b\w/g, letter => letter.toUpperCase());

const templateGroups = computed(() => {
  if (!state.inboxId) return [];

  const templates = formState.getFilteredWhatsAppTemplates.value(state.inboxId);
  return groupWhatsAppTemplates(templates || []);
});

const templateOptions = computed(() => {
  return templateGroups.value.map(templateGroup => ({
    value: templateGroup.name,
    label: friendlyTemplateName(templateGroup.name),
  }));
});

const selectedTemplateGroup = computed(() => {
  if (!state.templateName) return null;

  return (
    templateGroups.value.find(
      templateGroup => templateGroup.name === state.templateName
    ) || null
  );
});

const templateLanguageOptions = computed(() => {
  return (
    selectedTemplateGroup.value?.variants.map(template => ({
      value: template.language,
      label: template.language,
    })) || []
  );
});

const selectedTemplate = computed(() => {
  if (!selectedTemplateGroup.value || !state.templateLanguage) return null;

  return (
    selectedTemplateGroup.value.variants.find(
      template => template.language === state.templateLanguage
    ) || null
  );
});

const getErrorMessage = field => {
  if (!v$.value[field].$error) return '';

  switch (field) {
    case 'title':
      return t('CAMPAIGN.WHATSAPP.CREATE.FORM.TITLE.ERROR');
    case 'inboxId':
      return t('CAMPAIGN.WHATSAPP.CREATE.FORM.INBOX.ERROR');
    case 'templateName':
      return t('CAMPAIGN.WHATSAPP.CREATE.FORM.TEMPLATE.ERROR');
    case 'templateLanguage':
      return t('CAMPAIGN.WHATSAPP.CREATE.FORM.TEMPLATE_LANGUAGE.ERROR');
    case 'scheduledAt':
      return t('CAMPAIGN.WHATSAPP.CREATE.FORM.SCHEDULED_AT.ERROR');
    case 'selectedAudience':
      return t('CAMPAIGN.WHATSAPP.CREATE.FORM.AUDIENCE.ERROR');
    default:
      return '';
  }
};

const formErrors = computed(() => ({
  title: getErrorMessage('title'),
  inbox: getErrorMessage('inboxId'),
  template: getErrorMessage('templateName'),
  templateLanguage: getErrorMessage('templateLanguage'),
  scheduledAt: getErrorMessage('scheduledAt'),
  audience: getErrorMessage('selectedAudience'),
}));

const hasRequiredTemplateParams = computed(() => {
  if (!selectedTemplate.value) return true;

  return templateParserRef.value?.isFormInvalid === false;
});

const formatToUTCString = localDateTime =>
  localDateTime ? new Date(localDateTime).toISOString() : null;

const previewPayload = computed(() => {
  const currentTemplate = selectedTemplate.value;
  const parserData = templateParserRef.value;

  return {
    title: state.title,
    message: parserData?.rawRenderedTemplate || '',
    template_params: {
      name: currentTemplate?.name || '',
      namespace: currentTemplate?.namespace || '',
      category: currentTemplate?.category || 'UTILITY',
      language: currentTemplate?.language || 'en_US',
      processed_params: parserData?.processedParams || {},
    },
    inbox_id: state.inboxId,
    scheduled_at: formatToUTCString(state.scheduledAt),
    audience: state.selectedAudience?.map(id => ({
      id,
      type: 'Label',
    })),
  };
});

const previewSignature = computed(() => JSON.stringify(previewPayload.value));

const isPreviewStale = computed(() => {
  if (!preview.value || !lastPreviewSignature.value) return false;
  return lastPreviewSignature.value !== previewSignature.value;
});

const canSubmit = computed(
  () =>
    !v$.value.$invalid &&
    hasRequiredTemplateParams.value &&
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
  const isTemplateValid =
    (await templateParserRef.value?.v$?.$validate?.()) ?? true;

  if (!isFormValid || !isTemplateValid) return;

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
  const isTemplateValid =
    (await templateParserRef.value?.v$?.$validate?.()) ?? true;
  if (!isFormValid || !isTemplateValid) return;
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

// Reset template selection when inbox changes
watch(
  () => state.inboxId,
  () => {
    state.templateName = null;
    state.templateLanguage = null;
    clearPreviewState();
  }
);

watch(
  () => state.templateName,
  () => {
    const variants = selectedTemplateGroup.value?.variants || [];
    state.templateLanguage =
      variants.length === 1 ? variants[0].language : null;
    clearPreviewState();
  }
);

watch(
  () => state.templateLanguage,
  () => {
    clearPreviewState();
  }
);

onMounted(clearPreviewState);
onBeforeUnmount(clearPreviewState);
</script>

<template>
  <form class="flex flex-col gap-4" @submit.prevent="handleSubmit">
    <Input
      v-model="state.title"
      :label="t('CAMPAIGN.WHATSAPP.CREATE.FORM.TITLE.LABEL')"
      :placeholder="t('CAMPAIGN.WHATSAPP.CREATE.FORM.TITLE.PLACEHOLDER')"
      :message="formErrors.title"
      :message-type="formErrors.title ? 'error' : 'info'"
    />

    <div class="flex flex-col gap-1">
      <label for="inbox" class="mb-0.5 text-sm font-medium text-n-slate-12">
        {{ t('CAMPAIGN.WHATSAPP.CREATE.FORM.INBOX.LABEL') }}
      </label>
      <ComboBox
        id="inbox"
        v-model="state.inboxId"
        :options="inboxOptions"
        :has-error="!!formErrors.inbox"
        :placeholder="t('CAMPAIGN.WHATSAPP.CREATE.FORM.INBOX.PLACEHOLDER')"
        :message="formErrors.inbox"
        class="[&>div>button]:bg-n-alpha-black2 [&>div>button:not(.focused)]:dark:outline-n-weak [&>div>button:not(.focused)]:hover:!outline-n-slate-6"
      />
    </div>

    <div class="flex flex-col gap-1">
      <label for="template" class="mb-0.5 text-sm font-medium text-n-slate-12">
        {{ t('CAMPAIGN.WHATSAPP.CREATE.FORM.TEMPLATE.LABEL') }}
      </label>
      <ComboBox
        id="template"
        v-model="state.templateName"
        :options="templateOptions"
        :has-error="!!formErrors.template"
        :placeholder="t('CAMPAIGN.WHATSAPP.CREATE.FORM.TEMPLATE.PLACEHOLDER')"
        :message="formErrors.template"
        class="[&>div>button]:bg-n-alpha-black2 [&>div>button:not(.focused)]:dark:outline-n-weak [&>div>button:not(.focused)]:hover:!outline-n-slate-6"
      />
      <p class="mt-1 text-xs text-n-slate-11">
        {{ t('CAMPAIGN.WHATSAPP.CREATE.FORM.TEMPLATE.INFO') }}
      </p>
    </div>

    <div v-if="selectedTemplateGroup" class="flex flex-col gap-1">
      <label
        for="template-language"
        class="mb-0.5 text-sm font-medium text-n-slate-12"
      >
        {{ t('CAMPAIGN.WHATSAPP.CREATE.FORM.TEMPLATE_LANGUAGE.LABEL') }}
      </label>
      <ComboBox
        id="template-language"
        v-model="state.templateLanguage"
        :options="templateLanguageOptions"
        :has-error="!!formErrors.templateLanguage"
        :placeholder="
          t('CAMPAIGN.WHATSAPP.CREATE.FORM.TEMPLATE_LANGUAGE.PLACEHOLDER')
        "
        :message="formErrors.templateLanguage"
        class="[&>div>button]:bg-n-alpha-black2 [&>div>button:not(.focused)]:dark:outline-n-weak [&>div>button:not(.focused)]:hover:!outline-n-slate-6"
      />
    </div>

    <!-- Template Parser -->
    <WhatsAppTemplateParser
      v-if="selectedTemplate"
      ref="templateParserRef"
      :template="selectedTemplate"
    />

    <div class="flex flex-col gap-1">
      <label for="audience" class="mb-0.5 text-sm font-medium text-n-slate-12">
        {{ t('CAMPAIGN.WHATSAPP.CREATE.FORM.AUDIENCE.LABEL') }}
      </label>
      <TagMultiSelectComboBox
        v-model="state.selectedAudience"
        :options="audienceList"
        :label="t('CAMPAIGN.WHATSAPP.CREATE.FORM.AUDIENCE.LABEL')"
        :placeholder="t('CAMPAIGN.WHATSAPP.CREATE.FORM.AUDIENCE.PLACEHOLDER')"
        :has-error="!!formErrors.audience"
        :message="formErrors.audience"
        class="[&>div>button]:bg-n-alpha-black2"
      />
    </div>

    <Input
      v-model="state.scheduledAt"
      :label="t('CAMPAIGN.WHATSAPP.CREATE.FORM.SCHEDULED_AT.LABEL')"
      type="datetime-local"
      :min="currentDateTime"
      :placeholder="t('CAMPAIGN.WHATSAPP.CREATE.FORM.SCHEDULED_AT.PLACEHOLDER')"
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

    <div class="flex gap-3 justify-between items-center w-full">
      <Button
        variant="faded"
        color="slate"
        type="button"
        :label="t('CAMPAIGN.WHATSAPP.CREATE.FORM.BUTTONS.CANCEL')"
        class="w-full bg-n-alpha-2 text-n-blue-11 hover:bg-n-alpha-3"
        @click="handleCancel"
      />
      <Button
        :label="t('CAMPAIGN.WHATSAPP.CREATE.FORM.BUTTONS.CREATE')"
        class="w-full"
        type="submit"
        :is-loading="isCreating"
        :disabled="isCreating || isPreviewing || !canSubmit"
      />
    </div>
  </form>
</template>
