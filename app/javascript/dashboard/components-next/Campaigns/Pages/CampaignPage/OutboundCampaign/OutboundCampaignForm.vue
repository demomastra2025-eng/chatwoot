<script setup>
import {
  reactive,
  computed,
  watch,
  ref,
  onMounted,
  onBeforeUnmount,
} from 'vue';
import { debounce } from '@chatwoot/utils';
import { useI18n } from 'vue-i18n';
import { useVuelidate } from '@vuelidate/core';
import { required, minLength } from '@vuelidate/validators';
import { useMapGetter, useStore } from 'dashboard/composables/store';
import { useAlert } from 'dashboard/composables';
import { INBOX_TYPES, TWILIO_CHANNEL_MEDIUM } from 'dashboard/helper/inbox.js';

import Input from 'dashboard/components-next/input/Input.vue';
import SchedulingDateTimeField from 'dashboard/components-next/Scheduling/SchedulingDateTimeField.vue';
import SchedulingFormFieldGroup from 'dashboard/components-next/Scheduling/SchedulingFormFieldGroup.vue';
import SchedulingSelectField from 'dashboard/components-next/Scheduling/SchedulingSelectField.vue';
import TagMultiSelectComboBox from 'dashboard/components-next/combobox/TagMultiSelectComboBox.vue';
import TouchMessageComposer from 'dashboard/components-next/Outbound/TouchMessageComposer.vue';
import CampaignPreviewSummary from 'dashboard/components-next/Campaigns/Pages/CampaignPage/CampaignPreviewSummary.vue';
import { detectTouchTextMode } from 'dashboard/components-next/Outbound/touchTextMode';
import {
  buildTouchContentModeTabs,
  isWhatsAppTemplateCapableChannel,
  normalizeTouchContentKindForCapabilities,
} from 'dashboard/components-next/Outbound/touchContentModes';
import { groupWhatsAppTemplates } from 'dashboard/helper/whatsappTemplateLibrary';

const props = defineProps({
  inboxScope: {
    type: String,
    default: 'outbound',
  },
});

const emit = defineEmits(['submit']);

const { t } = useI18n();
const store = useStore();

const formState = {
  uiFlags: useMapGetter('campaigns/getUIFlags'),
  labels: useMapGetter('labels/getLabels'),
  inboxes: useMapGetter('inboxes/getOutboundCampaignInboxes'),
  getFilteredWhatsAppTemplates: useMapGetter(
    'inboxes/getFilteredWhatsAppTemplates'
  ),
  cannedResponses: useMapGetter('getCannedResponses'),
};

const initialState = {
  instructions: '',
  title: '',
  message: '',
  inboxId: null,
  contentKind: 'free_text',
  templateName: null,
  templateLanguage: null,
  scheduledAt: null,
  selectedAudience: [],
  useAiAuthoring: false,
};

const state = reactive({ ...initialState });
const messageComposerRef = ref(null);
const templateState = ref({ processedParams: {}, rawRenderedTemplate: '' });
const lastPreviewSignature = ref(null);

const matchesInboxScope = inbox => {
  if (props.inboxScope === 'sms') {
    return (
      inbox.channel_type === INBOX_TYPES.SMS ||
      (inbox.channel_type === INBOX_TYPES.TWILIO &&
        inbox.medium === TWILIO_CHANNEL_MEDIUM.SMS)
    );
  }

  if (props.inboxScope === 'whatsapp') {
    return isWhatsAppTemplateCapableChannel({
      channelType: inbox.channel_type,
      medium: inbox.medium,
    });
  }

  return true;
};

const scopedInboxes = computed(() =>
  (formState.inboxes.value || []).filter(matchesInboxScope)
);

const selectedInbox = computed(
  () =>
    scopedInboxes.value.find(
      inbox => Number(inbox.id) === Number(state.inboxId)
    ) || null
);

const selectedInboxCapabilities = computed(
  () => selectedInbox.value?.campaign_capabilities || {}
);

const isEmailInbox = computed(
  () => selectedInbox.value?.channel_type === INBOX_TYPES.EMAIL
);

const isWhatsAppTemplateCapable = computed(() =>
  isWhatsAppTemplateCapableChannel({
    channelType: selectedInbox.value?.channel_type,
    medium: selectedInbox.value?.medium,
  })
);
const isChannelTemplate = computed(
  () => state.contentKind === 'channel_template'
);
const requiresTemplate = computed(() => isChannelTemplate.value);

const supportsAiAuthoring = computed(() => {
  if (!selectedInbox.value || requiresTemplate.value) {
    return false;
  }

  if (!selectedInbox.value.captainAssistant?.id) {
    return false;
  }

  return !(
    selectedInbox.value.channel_type === INBOX_TYPES.SMS ||
    (selectedInbox.value.channel_type === INBOX_TYPES.TWILIO &&
      selectedInbox.value.medium !== TWILIO_CHANNEL_MEDIUM.WHATSAPP)
  );
});

const rules = computed(() => ({
  title: { required, minLength: minLength(1) },
  message:
    requiresTemplate.value || state.useAiAuthoring
      ? {}
      : { required, minLength: minLength(1) },
  instructions:
    !requiresTemplate.value && state.useAiAuthoring
      ? { required, minLength: minLength(1) }
      : {},
  inboxId: { required },
  templateName: requiresTemplate.value ? { required } : {},
  templateLanguage: requiresTemplate.value ? { required } : {},
  scheduledAt: { required },
  selectedAudience: { required },
}));

const v$ = useVuelidate(rules, state);

const isCreating = computed(() => formState.uiFlags.value.isCreating);
const isPreviewing = computed(() => formState.uiFlags.value.isPreviewing);
const preview = computed(() => store.getters['campaigns/getPreview']);

const mapToOptions = (items, valueKey, labelKey) =>
  items?.map(item => ({
    value: item[valueKey],
    label: item[labelKey],
  })) ?? [];

const buildFreeTextTemplateOption = template => ({
  value: template.id || template.short_code,
  label: template.short_code || template.name || `#${template.id}`,
  content: template.content || '',
});

const channelLabel = inbox => {
  if (inbox.channel_type === INBOX_TYPES.TWILIO) {
    return inbox.medium === TWILIO_CHANNEL_MEDIUM.WHATSAPP
      ? 'Twilio WhatsApp'
      : 'Twilio SMS';
  }

  switch (inbox.channel_type) {
    case INBOX_TYPES.SMS:
      return 'SMS';
    case INBOX_TYPES.WHATSAPP:
      return 'WhatsApp';
    case INBOX_TYPES.WHATSAPP_WEB:
      return 'WhatsApp Web';
    case INBOX_TYPES.TELEGRAM:
      return 'Telegram';
    case INBOX_TYPES.EMAIL:
      return 'Email';
    case INBOX_TYPES.TELEGRAM_PERSONAL:
      return 'Telegram Personal';
    case INBOX_TYPES.VK:
      return 'VK';
    case INBOX_TYPES.LINE:
      return 'Line';
    case INBOX_TYPES.FB:
      return 'Messenger';
    case INBOX_TYPES.INSTAGRAM:
      return 'Instagram';
    case INBOX_TYPES.TIKTOK:
      return 'TikTok';
    case INBOX_TYPES.TWITTER:
      return 'Twitter DM';
    default:
      return inbox.name;
  }
};

const audienceList = computed(() =>
  mapToOptions(formState.labels.value, 'id', 'title')
);

const inboxOptions = computed(
  () =>
    scopedInboxes.value.map(inbox => ({
      value: inbox.id,
      label: `${inbox.name} · ${channelLabel(inbox)}`,
    })) ?? []
);

const freeTextTemplateOptions = computed(() =>
  (formState.cannedResponses.value || [])
    .filter(template => template?.short_code && template?.content)
    .map(buildFreeTextTemplateOption)
);
const hasFreeTextTemplates = computed(
  () => freeTextTemplateOptions.value.length > 0
);

const contentModeTabs = computed(() =>
  buildTouchContentModeTabs({
    t,
    supportsFreeText: hasFreeTextTemplates.value,
    supportsWhatsAppTemplates: isWhatsAppTemplateCapable.value,
  })
);

const activeContentTabIndex = computed(() => {
  const tabIndex = contentModeTabs.value.findIndex(
    tab => tab.id === state.contentKind
  );

  return tabIndex === -1 ? 0 : tabIndex;
});

const contentModeTabId = computed(
  () => `outbound-campaign-content-${state.inboxId || 'new'}`
);

const handleContentTabChanged = tab => {
  state.contentKind = tab.id;
};

const friendlyTemplateName = templateName =>
  templateName
    .replace(/_/g, ' ')
    .replace(/\b\w/g, letter => letter.toUpperCase());

const templateGroups = computed(() => {
  if (!state.inboxId || !requiresTemplate.value) return [];

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
      return t('CAMPAIGN.OUTBOUND.CREATE.FORM.TITLE.ERROR');
    case 'message':
      return t('CAMPAIGN.OUTBOUND.CREATE.FORM.MESSAGE.ERROR');
    case 'instructions':
      return t('CAMPAIGN.OUTBOUND.CREATE.FORM.INSTRUCTIONS.ERROR');
    case 'inboxId':
      return t('CAMPAIGN.OUTBOUND.CREATE.FORM.INBOX.ERROR');
    case 'templateName':
      return t('CAMPAIGN.OUTBOUND.CREATE.FORM.TEMPLATE.ERROR');
    case 'templateLanguage':
      return t('CAMPAIGN.OUTBOUND.CREATE.FORM.TEMPLATE_LANGUAGE.ERROR');
    case 'scheduledAt':
      return t('CAMPAIGN.OUTBOUND.CREATE.FORM.SCHEDULED_AT.ERROR');
    case 'selectedAudience':
      return t('CAMPAIGN.OUTBOUND.CREATE.FORM.AUDIENCE.ERROR');
    default:
      return '';
  }
};

const formErrors = computed(() => ({
  title: getErrorMessage('title'),
  message: getErrorMessage('message'),
  instructions: getErrorMessage('instructions'),
  inbox: getErrorMessage('inboxId'),
  template: getErrorMessage('templateName'),
  templateLanguage: getErrorMessage('templateLanguage'),
  scheduledAt: getErrorMessage('scheduledAt'),
  audience: getErrorMessage('selectedAudience'),
}));

const titleHelpMessage = computed(() => {
  if (formErrors.value.title) return formErrors.value.title;
  if (isEmailInbox.value && selectedInboxCapabilities.value.supports_subject) {
    return t('CAMPAIGN.OUTBOUND.CREATE.FORM.TITLE.EMAIL_INFO');
  }

  return '';
});

const messageHelpMessage = computed(() => {
  if (state.useAiAuthoring) {
    return formErrors.value.instructions;
  }

  if (formErrors.value.message) return formErrors.value.message;
  if (isEmailInbox.value && selectedInboxCapabilities.value.supports_html) {
    return t('CAMPAIGN.OUTBOUND.CREATE.FORM.MESSAGE.EMAIL_INFO');
  }

  return '';
});

const hasRequiredTemplateParams = computed(() => {
  if (!requiresTemplate.value || !selectedTemplate.value) return true;

  return messageComposerRef.value?.isTemplateReady?.() === true;
});

const formatToUTCString = localDateTime =>
  localDateTime ? new Date(localDateTime).toISOString() : null;

const resolvedPreviewMessage = computed(() => {
  if (requiresTemplate.value) {
    return templateState.value.rawRenderedTemplate || '';
  }

  if (state.useAiAuthoring) {
    return '';
  }

  return state.message;
});

const previewPayload = computed(() => {
  const payload = {
    instructions:
      !requiresTemplate.value && state.useAiAuthoring
        ? state.instructions.trim()
        : '',
    title: state.title,
    message: resolvedPreviewMessage.value,
    inbox_id: state.inboxId,
    scheduled_at: formatToUTCString(state.scheduledAt),
    audience: state.selectedAudience?.map(id => ({
      id,
      type: 'Label',
    })),
    text_mode: requiresTemplate.value
      ? 'static'
      : detectTouchTextMode({
          body: state.message,
          instructions: state.instructions,
          useAiAuthoring: state.useAiAuthoring,
        }),
  };

  if (requiresTemplate.value) {
    payload.template_params = {
      name: selectedTemplate.value?.name || '',
      namespace: selectedTemplate.value?.namespace || '',
      category: selectedTemplate.value?.category || 'UTILITY',
      language: selectedTemplate.value?.language || 'en_US',
      processed_params: templateState.value.processedParams || {},
    };
  }

  return payload;
});

const previewSignature = computed(() => JSON.stringify(previewPayload.value));
const canAutoPreviewTemplateCampaign = computed(() => {
  if (!requiresTemplate.value) {
    return false;
  }

  return Boolean(
    String(state.title || '').trim() &&
      state.inboxId &&
      state.templateName &&
      state.templateLanguage &&
      state.scheduledAt &&
      state.selectedAudience?.length &&
      selectedTemplate.value &&
      hasRequiredTemplateParams.value
  );
});

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

const prepareCampaignDetails = () => previewPayload.value;

const validateTemplate = async () =>
  requiresTemplate.value
    ? ((await messageComposerRef.value?.validateTemplate?.()) ?? true)
    : true;

const handlePreview = async () => {
  const isFormValid = await v$.value.$validate();
  const isTemplateValid = await validateTemplate();

  if (!isFormValid || !isTemplateValid) return;

  try {
    await store.dispatch('campaigns/preview', prepareCampaignDetails());
    lastPreviewSignature.value = previewSignature.value;
  } catch {
    lastPreviewSignature.value = null;
    useAlert(t('CAMPAIGN.PREVIEW.ERROR_MESSAGE'));
  }
};

const runAutoPreview = debounce(async () => {
  if (!canAutoPreviewTemplateCampaign.value) {
    return;
  }

  try {
    await store.dispatch('campaigns/preview', prepareCampaignDetails());
    lastPreviewSignature.value = previewSignature.value;
  } catch {
    lastPreviewSignature.value = null;
  }
}, 350);

const handleSubmit = async () => {
  const isFormValid = await v$.value.$validate();
  const isTemplateValid = await validateTemplate();
  if (!isFormValid || !isTemplateValid) return false;
  if (
    !preview.value ||
    isPreviewStale.value ||
    preview.value.deliverable_count < 1
  ) {
    useAlert(t('CAMPAIGN.PREVIEW.SUBMIT_REQUIRES_PREVIEW'));
    return false;
  }

  emit('submit', prepareCampaignDetails());
  return true;
};

const handleTemplateStateChange = payload => {
  templateState.value = {
    processedParams: payload?.processedParams || {},
    rawRenderedTemplate: String(payload?.rawRenderedTemplate || ''),
  };
};

const bodyEditorId = 'outbound-campaign-message';
const instructionsEditorId = 'outbound-campaign-instructions';
const hasMessageError = computed(() => {
  return state.useAiAuthoring
    ? !!formErrors.value.instructions
    : !!formErrors.value.message;
});

watch(
  () => state.inboxId,
  () => {
    state.contentKind = normalizeTouchContentKindForCapabilities({
      contentKind: state.contentKind,
      supportsWhatsAppTemplates: isWhatsAppTemplateCapable.value,
    });
    state.templateName = null;
    state.templateLanguage = null;
    state.useAiAuthoring = false;
    templateState.value = { processedParams: {}, rawRenderedTemplate: '' };
    clearPreviewState();
  }
);

watch(
  () => supportsAiAuthoring.value,
  value => {
    if (!value) {
      state.useAiAuthoring = false;
    }
  }
);

watch(
  () => state.contentKind,
  value => {
    if (value !== 'channel_template') {
      state.templateName = null;
      state.templateLanguage = null;
      templateState.value = { processedParams: {}, rawRenderedTemplate: '' };
    }

    if (value === 'channel_template') {
      state.useAiAuthoring = false;
    }

    clearPreviewState();
  }
);

watch(
  () => contentModeTabs.value.map(tab => tab.id).join('|'),
  () => {
    if (contentModeTabs.value.length === 0) {
      return;
    }

    const hasCurrentTab = contentModeTabs.value.some(
      tab => tab.id === state.contentKind
    );
    if (!hasCurrentTab) {
      state.contentKind = contentModeTabs.value[0].id;
    }
  }
);

watch(
  () => state.templateName,
  () => {
    const variants = selectedTemplateGroup.value?.variants || [];
    state.templateLanguage =
      variants.length === 1 ? variants[0].language : null;
    templateState.value = { processedParams: {}, rawRenderedTemplate: '' };
    clearPreviewState();
  }
);

watch(
  () => state.templateLanguage,
  () => {
    templateState.value = { processedParams: {}, rawRenderedTemplate: '' };
    clearPreviewState();
  }
);

watch(
  () => [previewSignature.value, canAutoPreviewTemplateCampaign.value],
  ([, canAutoPreview]) => {
    if (!requiresTemplate.value) {
      return;
    }

    if (!canAutoPreview) {
      clearPreviewState();
      return;
    }

    runAutoPreview();
  }
);

onMounted(() => {
  clearPreviewState();
  store.dispatch('getCannedResponse', { searchKey: '' });
});
onBeforeUnmount(clearPreviewState);

defineExpose({
  canSubmit,
  handlePreview,
  handleSubmit,
  isCreating,
  isPreviewing,
});
</script>

<template>
  <form class="grid gap-5" @submit.prevent>
    <div
      class="rounded-xl bg-n-brand/5 px-4 py-4 outline outline-1 outline-n-brand/10"
    >
      <p class="mb-1 text-sm font-semibold text-n-slate-12">
        {{ t('CAMPAIGN.OUTBOUND.CREATE.SECTIONS.DETAILS.TITLE') }}
      </p>
      <p class="mb-0 text-sm leading-6 text-n-slate-11">
        {{ t('CAMPAIGN.OUTBOUND.CREATE.SECTIONS.DETAILS.DESCRIPTION') }}
      </p>
    </div>

    <SchedulingFormFieldGroup :framed="false">
      <div class="grid gap-4">
        <Input
          v-model="state.title"
          :label="t('CAMPAIGN.OUTBOUND.CREATE.FORM.TITLE.LABEL')"
          :placeholder="t('CAMPAIGN.OUTBOUND.CREATE.FORM.TITLE.PLACEHOLDER')"
          :message="titleHelpMessage"
          :message-type="formErrors.title ? 'error' : 'info'"
        />

        <SchedulingSelectField
          v-model="state.inboxId"
          :label="t('CAMPAIGN.OUTBOUND.CREATE.FORM.INBOX.LABEL')"
          :options="inboxOptions"
          :placeholder="t('CAMPAIGN.OUTBOUND.CREATE.FORM.INBOX.PLACEHOLDER')"
          :message="formErrors.inbox"
          :has-error="!!formErrors.inbox"
        />
      </div>
    </SchedulingFormFieldGroup>

    <SchedulingFormFieldGroup :framed="false">
      <TouchMessageComposer
        ref="messageComposerRef"
        :active-content-tab-index="activeContentTabIndex"
        :allow-ai-authoring="supportsAiAuthoring"
        :body="state.message"
        :body-editor-id="bodyEditorId"
        :body-label="t('CAMPAIGN.OUTBOUND.CREATE.FORM.MESSAGE.LABEL')"
        :body-placeholder="
          t('CAMPAIGN.OUTBOUND.CREATE.FORM.MESSAGE.PLACEHOLDER')
        "
        :channel-type="selectedInbox?.channel_type || ''"
        :content-kind="state.contentKind"
        :content-mode-tab-id="contentModeTabId"
        :content-mode-tabs="contentModeTabs"
        :editor-message="messageHelpMessage"
        :editor-message-type="hasMessageError ? 'error' : 'info'"
        :enable-attachments="false"
        :free-text-template-options="freeTextTemplateOptions"
        :instructions="state.instructions"
        :instructions-editor-id="instructionsEditorId"
        :instructions-placeholder="
          t('CAMPAIGN.OUTBOUND.CREATE.FORM.INSTRUCTIONS.PLACEHOLDER')
        "
        :medium="selectedInbox?.medium || ''"
        :selected-template="selectedTemplate"
        :selected-template-group="selectedTemplateGroup"
        :template-language="state.templateLanguage || ''"
        :template-language-options="templateLanguageOptions"
        :template-name="state.templateName || ''"
        :template-options="templateOptions"
        :template-params="templateState.processedParams || {}"
        :use-ai-authoring="state.useAiAuthoring"
        @content-tab-change="handleContentTabChanged"
        @template-state-change="handleTemplateStateChange"
        @update:body="state.message = $event"
        @update:instructions="state.instructions = $event"
        @update:template-language="state.templateLanguage = $event"
        @update:template-name="state.templateName = $event"
        @update:use-ai-authoring="state.useAiAuthoring = $event"
      />
    </SchedulingFormFieldGroup>

    <SchedulingFormFieldGroup :framed="false">
      <TagMultiSelectComboBox
        v-model="state.selectedAudience"
        :options="audienceList"
        :label="t('CAMPAIGN.OUTBOUND.CREATE.FORM.AUDIENCE.LABEL')"
        :placeholder="t('CAMPAIGN.OUTBOUND.CREATE.FORM.AUDIENCE.PLACEHOLDER')"
        :has-error="!!formErrors.audience"
        :message="formErrors.audience"
        class="[&>div>button]:bg-n-solid-1 [&>div>button]:outline [&>div>button]:outline-1 [&>div>button]:outline-n-weak"
      />
    </SchedulingFormFieldGroup>

    <SchedulingFormFieldGroup :framed="false">
      <SchedulingDateTimeField
        v-model="state.scheduledAt"
        :label="t('CAMPAIGN.OUTBOUND.CREATE.FORM.SCHEDULED_AT.LABEL')"
        :placeholder="
          t('CAMPAIGN.OUTBOUND.CREATE.FORM.SCHEDULED_AT.PLACEHOLDER')
        "
        :message="formErrors.scheduledAt"
        :message-type="formErrors.scheduledAt ? 'error' : 'info'"
      />
    </SchedulingFormFieldGroup>

    <SchedulingFormFieldGroup :framed="false">
      <div class="grid gap-3">
        <CampaignPreviewSummary :preview="preview" :stale="isPreviewStale" />
        <p class="mb-0 text-xs leading-5 text-n-slate-11">
          {{ previewHint }}
        </p>
      </div>
    </SchedulingFormFieldGroup>
  </form>
</template>
