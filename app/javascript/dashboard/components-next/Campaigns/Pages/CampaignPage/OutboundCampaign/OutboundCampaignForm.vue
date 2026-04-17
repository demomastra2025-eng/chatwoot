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

import Button from 'dashboard/components-next/button/Button.vue';
import Input from 'dashboard/components-next/input/Input.vue';
import SchedulingDateTimeField from 'dashboard/components-next/Scheduling/SchedulingDateTimeField.vue';
import SchedulingFormFieldGroup from 'dashboard/components-next/Scheduling/SchedulingFormFieldGroup.vue';
import SchedulingSelectField from 'dashboard/components-next/Scheduling/SchedulingSelectField.vue';
import TagMultiSelectComboBox from 'dashboard/components-next/combobox/TagMultiSelectComboBox.vue';
import WhatsAppTemplateParser from 'dashboard/components-next/whatsapp/WhatsAppTemplateParser.vue';
import CampaignPreviewSummary from 'dashboard/components-next/Campaigns/Pages/CampaignPage/CampaignPreviewSummary.vue';
import WootMessageEditor from 'dashboard/components/widgets/WootWriter/Editor.vue';
import { detectTouchTextMode } from 'dashboard/components-next/Outbound/touchTextMode';
import { groupWhatsAppTemplates } from 'dashboard/helper/whatsappTemplateLibrary';

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
};

const initialState = {
  instructions: '',
  title: '',
  message: '',
  inboxId: null,
  templateName: null,
  templateLanguage: null,
  scheduledAt: null,
  selectedAudience: [],
  useAiAuthoring: false,
};

const state = reactive({ ...initialState });
const templateParserRef = ref(null);
const lastPreviewSignature = ref(null);

const selectedInbox = computed(
  () =>
    formState.inboxes.value?.find(inbox => inbox.id === state.inboxId) || null
);

const selectedInboxCapabilities = computed(
  () => selectedInbox.value?.campaign_capabilities || {}
);

const isEmailInbox = computed(
  () => selectedInbox.value?.channel_type === INBOX_TYPES.EMAIL
);

const requiresTemplate = computed(() => {
  if (!selectedInbox.value) return false;

  return (
    selectedInbox.value.channel_type === INBOX_TYPES.WHATSAPP ||
    (selectedInbox.value.channel_type === INBOX_TYPES.TWILIO &&
      selectedInbox.value.medium === TWILIO_CHANNEL_MEDIUM.WHATSAPP)
  );
});

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
    formState.inboxes.value?.map(inbox => ({
      value: inbox.id,
      label: `${inbox.name} · ${channelLabel(inbox)}`,
    })) ?? []
);

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

  return templateParserRef.value?.isFormInvalid === false;
});

const formatToUTCString = localDateTime =>
  localDateTime ? new Date(localDateTime).toISOString() : null;

const resolvedPreviewMessage = computed(() => {
  if (requiresTemplate.value) {
    return templateParserRef.value?.rawRenderedTemplate || '';
  }

  if (state.useAiAuthoring) {
    return '';
  }

  return state.message;
});

const previewPayload = computed(() => {
  const parserData = templateParserRef.value;
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
      processed_params: parserData?.processedParams || {},
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
    ? ((await templateParserRef.value?.v$?.$validate?.()) ?? true)
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

const aiToggleButtonClass = isEnabled => {
  return isEnabled
    ? '!bg-n-violet-3 !text-n-violet-9 hover:enabled:!bg-n-violet-4 focus-visible:!bg-n-violet-4 !outline-transparent'
    : '';
};

const campaignEditorClass = isAiAuthoring => {
  return [
    'touch-rich-editor w-full min-w-0 max-w-full overflow-visible rounded-2xl px-3 py-2 transition-all duration-200',
    'campaign-editor-large',
    isAiAuthoring
      ? 'bg-n-violet-3 ring-1 ring-inset ring-n-violet-6/20'
      : 'bg-n-solid-1 outline outline-1 outline-n-weak dark:outline-n-strong',
  ].join(' ');
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
    state.templateName = null;
    state.templateLanguage = null;
    state.useAiAuthoring = false;
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

onMounted(clearPreviewState);
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
    <SchedulingFormFieldGroup
      :framed="false"
      :title="t('CAMPAIGN.OUTBOUND.CREATE.SECTIONS.DETAILS.TITLE')"
      :description="t('CAMPAIGN.OUTBOUND.CREATE.SECTIONS.DETAILS.DESCRIPTION')"
    >
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
    </SchedulingFormFieldGroup>

    <SchedulingFormFieldGroup
      :framed="false"
      :title="t('CAMPAIGN.OUTBOUND.CREATE.SECTIONS.MESSAGE.TITLE')"
      :description="t('CAMPAIGN.OUTBOUND.CREATE.SECTIONS.MESSAGE.DESCRIPTION')"
    >
      <template v-if="requiresTemplate">
        <SchedulingSelectField
          v-model="state.templateName"
          :label="t('CAMPAIGN.OUTBOUND.CREATE.FORM.TEMPLATE.LABEL')"
          :options="templateOptions"
          :placeholder="t('CAMPAIGN.OUTBOUND.CREATE.FORM.TEMPLATE.PLACEHOLDER')"
          :message="
            formErrors.template ||
            t('CAMPAIGN.OUTBOUND.CREATE.FORM.TEMPLATE.INFO')
          "
          :has-error="!!formErrors.template"
        />

        <SchedulingSelectField
          v-if="selectedTemplateGroup"
          v-model="state.templateLanguage"
          :label="t('CAMPAIGN.OUTBOUND.CREATE.FORM.TEMPLATE_LANGUAGE.LABEL')"
          :options="templateLanguageOptions"
          :placeholder="
            t('CAMPAIGN.OUTBOUND.CREATE.FORM.TEMPLATE_LANGUAGE.PLACEHOLDER')
          "
          :message="formErrors.templateLanguage"
          :has-error="!!formErrors.templateLanguage"
        />

        <WhatsAppTemplateParser
          v-if="selectedTemplate"
          ref="templateParserRef"
          :template="selectedTemplate"
        />
      </template>

      <template v-else>
        <div class="flex items-center justify-between gap-3">
          <p class="mb-0 text-sm font-medium text-n-slate-12">
            {{ t('CAMPAIGN.OUTBOUND.CREATE.FORM.MESSAGE.LABEL') }}
          </p>
          <Button
            v-if="supportsAiAuthoring"
            v-tooltip.top-end="
              t('OUTBOUND_WORKSPACE.TOUCH_EDITOR.FIELDS.AI_AGENT')
            "
            icon="i-woot-captain"
            :variant="state.useAiAuthoring ? 'solid' : 'faded'"
            color="slate"
            size="sm"
            :aria-pressed="state.useAiAuthoring"
            :class="aiToggleButtonClass(state.useAiAuthoring)"
            @click="state.useAiAuthoring = !state.useAiAuthoring"
          />
        </div>

        <WootMessageEditor
          v-if="!state.useAiAuthoring"
          :model-value="state.message"
          :editor-id="bodyEditorId"
          :class="campaignEditorClass(false)"
          :channel-type="selectedInbox?.channel_type || ''"
          :medium="selectedInbox?.medium || ''"
          enable-variables
          enable-captain-fields
          enable-canned-responses
          canned-menu-placement="bottom"
          :canned-menu-visible-items="3"
          :placeholder="t('CAMPAIGN.OUTBOUND.CREATE.FORM.MESSAGE.PLACEHOLDER')"
          @update:model-value="state.message = $event"
        />

        <WootMessageEditor
          v-else
          :model-value="state.instructions"
          :editor-id="instructionsEditorId"
          :class="campaignEditorClass(true)"
          :channel-type="selectedInbox?.channel_type || ''"
          :medium="selectedInbox?.medium || ''"
          enable-variables
          enable-captain-fields
          enable-canned-responses
          canned-menu-placement="bottom"
          :canned-menu-visible-items="3"
          :placeholder="
            t('CAMPAIGN.OUTBOUND.CREATE.FORM.INSTRUCTIONS.PLACEHOLDER')
          "
          @update:model-value="state.instructions = $event"
        />

        <p
          class="mb-0 text-xs"
          :class="hasMessageError ? 'text-n-ruby-9' : 'text-n-slate-11'"
        >
          {{ messageHelpMessage }}
        </p>
      </template>
    </SchedulingFormFieldGroup>

    <SchedulingFormFieldGroup
      :framed="false"
      :title="t('CAMPAIGN.OUTBOUND.CREATE.SECTIONS.AUDIENCE.TITLE')"
      :description="t('CAMPAIGN.OUTBOUND.CREATE.SECTIONS.AUDIENCE.DESCRIPTION')"
    >
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

    <SchedulingFormFieldGroup
      :framed="false"
      :title="t('CAMPAIGN.OUTBOUND.CREATE.SECTIONS.SCHEDULE.TITLE')"
      :description="t('CAMPAIGN.OUTBOUND.CREATE.SECTIONS.SCHEDULE.DESCRIPTION')"
    >
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

    <SchedulingFormFieldGroup
      :framed="false"
      :title="t('CAMPAIGN.PREVIEW.TITLE')"
      :description="previewHint"
    >
      <CampaignPreviewSummary :preview="preview" :stale="isPreviewStale" />
    </SchedulingFormFieldGroup>
  </form>
</template>

<style scoped>
.campaign-editor-large {
  min-height: 13rem;
}

.touch-rich-editor :deep(.ProseMirror-menubar-wrapper),
.touch-rich-editor :deep(.ProseMirror),
.touch-rich-editor :deep(.ProseMirror-menubar) {
  min-width: 0;
  width: 100%;
  max-width: 100%;
}

.campaign-editor-large :deep(.ProseMirror) {
  min-height: 8.5rem;
}

.touch-rich-editor :deep(.mention--box),
.touch-rich-editor :deep(.copilot-editor-menu) {
  z-index: 70;
}
</style>
