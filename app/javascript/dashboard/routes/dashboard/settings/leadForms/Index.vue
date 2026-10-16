<script setup>
import { computed, onMounted, reactive, ref, watch } from 'vue';
import { useI18n } from 'vue-i18n';
import { useRoute, useRouter } from 'vue-router';
import { useStore } from 'vuex';
import { useMapGetter } from 'dashboard/composables/store';
import { useAlert } from 'dashboard/composables';
import { useCrmReferencesStore } from 'dashboard/stores/crm/references';
import Button from 'dashboard/components-next/button/Button.vue';
import ComboBox from 'dashboard/components-next/combobox/ComboBox.vue';
import Input from 'dashboard/components-next/input/Input.vue';
import TabBar from 'dashboard/components-next/tabbar/TabBar.vue';
import BaseSettingsHeader from '../components/BaseSettingsHeader.vue';
import { getInboxFlowRouteName } from 'dashboard/routes/dashboard/settings/inbox/helpers/inboxFlowRoutes';
import leadFormsAPI from 'dashboard/api/leadForms';
import { getInboxIconByType, INBOX_TYPES } from 'dashboard/helper/inbox';
import ApiFieldBuilder from './ApiFieldBuilder.vue';

const { t } = useI18n();
const route = useRoute();
const router = useRouter();
const store = useStore();
const referencesStore = useCrmReferencesStore();

const forms = ref([]);
const savingSource = ref('');
const updatingFormId = ref(null);
const activeTab = ref('meta');
const selectedMetaConnectionId = ref('');
const initializedDefaultPipeline = reactive({
  api: false,
  meta: false,
});
const apiForm = reactive({
  name: '',
  inboxId: '',
  pipelineId: '',
  stageId: '',
});
const metaForm = reactive({
  name: '',
  inboxId: '',
  pipelineId: '',
  stageId: '',
  metaFormId: '',
  metaPageId: '',
  verifyToken: '',
});
const inboxes = useMapGetter('inboxes/getInboxes');

const accountId = computed(() => route.params.accountId);
const publicApiOrigin = window.location.origin;

const backToPipelinesRoute = computed(() => ({
  name: 'crm_settings_index',
  params: { accountId: accountId.value },
  ...(route.query?.pipelineId
    ? { query: { pipelineId: String(route.query.pipelineId) } }
    : {}),
}));

const activePipelines = computed(() =>
  (referencesStore.pipelines || []).filter(
    pipeline => pipeline.active !== false
  )
);

const pipelineOptions = computed(() => [
  { value: '', label: t('LEAD_FORMS.SELECT_PIPELINE') },
  ...activePipelines.value.map(pipeline => ({
    value: String(pipeline.id),
    label: pipeline.name,
  })),
]);

const openStagesForPipeline = pipelineId => {
  if (!pipelineId) return [];
  const pipeline = activePipelines.value.find(
    item => String(item.id) === String(pipelineId)
  );
  return (pipeline?.stages || []).filter(
    stage => stage.active !== false && stage.outcome === 'open'
  );
};

const stageOptionsForPipeline = pipelineId =>
  openStagesForPipeline(pipelineId).map(stage => ({
    value: String(stage.id),
    label: stage.name,
  }));

const defaultStageIdForPipeline = pipelineId => {
  const stages = openStagesForPipeline(pipelineId);
  const defaultStage = stages.find(stage => stage.default) || stages[0];
  return defaultStage ? String(defaultStage.id) : '';
};

const preferredPipelineId = computed(() => {
  const queryPipelineId = Array.isArray(route.query?.pipelineId)
    ? route.query.pipelineId[0]
    : route.query?.pipelineId;
  if (
    queryPipelineId &&
    activePipelines.value.some(
      pipeline => String(pipeline.id) === String(queryPipelineId)
    )
  ) {
    return String(queryPipelineId);
  }
  const defaultPipeline =
    activePipelines.value.find(pipeline => pipeline.default) ||
    activePipelines.value[0];
  return defaultPipeline ? String(defaultPipeline.id) : '';
});

const defaultApiFormFields = () => [
  {
    name: 'fullName',
    label: t('LEAD_FORMS.FIELDS.NAME'),
    placeholder: t('LEAD_FORMS.API_FORMS.FIELD_PLACEHOLDERS.NAME'),
    type: 'text',
    required: true,
    enabled: true,
  },
  {
    name: 'phoneNumber',
    label: t('LEAD_FORMS.FIELDS.PHONE'),
    placeholder: t('LEAD_FORMS.API_FORMS.FIELD_PLACEHOLDERS.PHONE'),
    type: 'tel',
    required: true,
    enabled: true,
  },
  {
    name: 'emailAddress',
    label: t('LEAD_FORMS.FIELDS.EMAIL'),
    placeholder: t('LEAD_FORMS.API_FORMS.FIELD_PLACEHOLDERS.EMAIL'),
    type: 'email',
    required: false,
    enabled: true,
  },
  {
    name: 'comment',
    label: t('LEAD_FORMS.FIELDS.COMMENT'),
    placeholder: t('LEAD_FORMS.API_FORMS.FIELD_PLACEHOLDERS.COMMENT'),
    type: 'textarea',
    required: false,
    enabled: true,
  },
];

const apiFormFields = ref(defaultApiFormFields());

const apiForms = computed(() =>
  forms.value.filter(form => form.source_kind === 'api')
);
const metaForms = computed(() =>
  forms.value.filter(form => form.source_kind === 'meta')
);

const tabs = computed(() => [
  { id: 'meta', label: t('LEAD_FORMS.TABS.META') },
  { id: 'api', label: t('LEAD_FORMS.TABS.API') },
]);

const activeTabIndex = computed(() =>
  Math.max(
    0,
    tabs.value.findIndex(tab => tab.id === activeTab.value)
  )
);

const switchTab = tab => {
  if (!tab?.id) return;

  activeTab.value = tab.id;
};

const excludedLeadTargetInboxTypes = new Set([
  INBOX_TYPES.WEB,
  INBOX_TYPES.EMAIL,
  INBOX_TYPES.API,
]);
const metaRegistrationInboxTypes = new Set([
  INBOX_TYPES.FB,
  INBOX_TYPES.INSTAGRAM,
  INBOX_TYPES.WHATSAPP,
]);

const inboxOption = inbox => ({
  value: inbox.id,
  label: inbox.name,
  icon: getInboxIconByType(inbox.channel_type, inbox.medium, 'fill'),
  iconClass: 'text-n-slate-11',
});

const leadTargetInboxOptions = computed(() =>
  inboxes.value
    .filter(inbox => !excludedLeadTargetInboxTypes.has(inbox.channel_type))
    .sort((a, b) => a.name.localeCompare(b.name))
    .map(inboxOption)
);

const metaConnectionOptions = computed(() =>
  inboxes.value
    .filter(inbox => metaRegistrationInboxTypes.has(inbox.channel_type))
    .sort((a, b) => a.name.localeCompare(b.name))
    .map(inboxOption)
);

const selectedMetaConnection = computed(() =>
  inboxes.value.find(
    inbox => String(inbox.id) === String(selectedMetaConnectionId.value)
  )
);

const metaRegistrationChannels = computed(() => [
  {
    key: 'facebook',
    title: t('LEAD_FORMS.META_FORMS.CONNECT_FACEBOOK'),
    icon: 'i-woot-messenger',
  },
  {
    key: 'instagram',
    title: t('LEAD_FORMS.META_FORMS.CONNECT_INSTAGRAM'),
    icon: 'i-woot-instagram',
  },
  {
    key: 'whatsapp',
    title: t('LEAD_FORMS.META_FORMS.CONNECT_WHATSAPP'),
    icon: 'i-woot-whatsapp',
  },
]);

const fetchLeadIntake = async () => {
  try {
    const formsResponse = await leadFormsAPI.get();
    forms.value = formsResponse.data.payload || [];
  } catch (error) {
    useAlert(t('LEAD_FORMS.ERRORS.LOAD'));
  }
};

const loadPage = async () => {
  try {
    await Promise.all([
      store.dispatch('inboxes/get'),
      store.dispatch('attributes/get'),
      referencesStore.fetchPipelines().catch(() => []),
      fetchLeadIntake(),
    ]);
  } catch (error) {
    useAlert(t('LEAD_FORMS.ERRORS.LOAD'));
  }
};

const isPhoneField = field =>
  ['phoneNumber', 'phone_number', 'phone', 'mobile'].includes(field?.name);

const enabledApiFields = () =>
  apiFormFields.value
    .filter(field => field.enabled || isPhoneField(field))
    .map(field => ({
      name: field.name?.trim(),
      label: field.label?.trim(),
      placeholder: field.placeholder?.trim(),
      type: isPhoneField(field) ? 'tel' : field.type || 'text',
      required: isPhoneField(field) || field.required === true,
    }))
    .filter(field => field.name && field.label);

const hasRequiredPhoneField = fields =>
  fields.some(field => isPhoneField(field) && field.required);

const defaultMetaFormFields = () => [
  {
    name: 'phone_number',
    label: t('LEAD_FORMS.FIELDS.PHONE'),
    placeholder: t('LEAD_FORMS.API_FORMS.FIELD_PLACEHOLDERS.PHONE'),
    type: 'tel',
    required: true,
    enabled: true,
  },
];

const createApiForm = async () => {
  const fieldSchema = enabledApiFields();

  if (
    !apiForm.name ||
    !apiForm.inboxId ||
    !fieldSchema.length ||
    !hasRequiredPhoneField(fieldSchema)
  ) {
    useAlert(t('LEAD_FORMS.ERRORS.REQUIRED'));
    return;
  }

  savingSource.value = 'api';
  try {
    await leadFormsAPI.create({
      name: apiForm.name,
      inbox_id: Number(apiForm.inboxId),
      pipeline_id: apiForm.pipelineId ? Number(apiForm.pipelineId) : null,
      stage_id:
        apiForm.pipelineId && apiForm.stageId ? Number(apiForm.stageId) : null,
      source_kind: 'api',
      status: 'active',
      field_schema: fieldSchema,
      settings: {
        conversation_status: 'open',
        auth_mode: 'public_token',
      },
    });
    apiForm.name = '';
    apiForm.inboxId = leadTargetInboxOptions.value[0]?.value || '';
    apiFormFields.value = defaultApiFormFields();
    useAlert(t('LEAD_FORMS.CREATED'));
    await fetchLeadIntake();
  } catch (error) {
    useAlert(t('LEAD_FORMS.ERRORS.SAVE'));
  } finally {
    savingSource.value = '';
  }
};

const createMetaForm = async () => {
  if (!metaConnectionOptions.value.length) {
    useAlert(t('LEAD_FORMS.META_FORMS.CONNECT_REQUIRED'));
    return;
  }

  if (
    !metaForm.name ||
    !metaForm.inboxId ||
    !metaForm.metaFormId ||
    !selectedMetaConnectionId.value
  ) {
    useAlert(t('LEAD_FORMS.META_FORMS.REQUIRED'));
    return;
  }

  savingSource.value = 'meta';
  try {
    await leadFormsAPI.create({
      name: metaForm.name,
      inbox_id: Number(metaForm.inboxId),
      pipeline_id: metaForm.pipelineId ? Number(metaForm.pipelineId) : null,
      stage_id:
        metaForm.pipelineId && metaForm.stageId
          ? Number(metaForm.stageId)
          : null,
      source_kind: 'meta',
      status: 'active',
      external_ref: metaForm.metaFormId,
      field_schema: defaultMetaFormFields(),
      settings: {
        conversation_status: 'open',
        meta_form_id: metaForm.metaFormId,
        meta_page_id: metaForm.metaPageId || undefined,
        verify_token: metaForm.verifyToken || undefined,
        meta_connection_inbox_id: Number(selectedMetaConnectionId.value),
        meta_connection_channel_type:
          selectedMetaConnection.value?.channel_type,
      },
    });
    metaForm.name = '';
    metaForm.metaFormId = '';
    metaForm.metaPageId = '';
    metaForm.verifyToken = '';
    metaForm.inboxId = leadTargetInboxOptions.value[0]?.value || '';
    useAlert(t('LEAD_FORMS.CREATED'));
    await fetchLeadIntake();
  } catch (error) {
    useAlert(t('LEAD_FORMS.ERRORS.SAVE'));
  } finally {
    savingSource.value = '';
  }
};

const updateFormPipeline = async (form, nextPipelineId) => {
  const pipelineId = nextPipelineId ? Number(nextPipelineId) : null;
  const nextStageId = pipelineId
    ? Number(defaultStageIdForPipeline(pipelineId) || 0) || null
    : null;
  updatingFormId.value = form.id;
  try {
    await leadFormsAPI.update(form.id, {
      pipeline_id: pipelineId,
      stage_id: nextStageId,
    });
    useAlert(t('LEAD_FORMS.UPDATED'));
    await fetchLeadIntake();
  } catch (error) {
    useAlert(t('LEAD_FORMS.ERRORS.SAVE'));
  } finally {
    updatingFormId.value = null;
  }
};

const updateFormStage = async (form, nextStageId) => {
  if (!form.pipeline_id) return;
  updatingFormId.value = form.id;
  try {
    await leadFormsAPI.update(form.id, {
      pipeline_id: Number(form.pipeline_id),
      stage_id: nextStageId ? Number(nextStageId) : null,
    });
    useAlert(t('LEAD_FORMS.UPDATED'));
    await fetchLeadIntake();
  } catch (error) {
    useAlert(t('LEAD_FORMS.ERRORS.SAVE'));
  } finally {
    updatingFormId.value = null;
  }
};

const openChannelRegistration = channel => {
  router.push({
    name: getInboxFlowRouteName(route, 'page'),
    params: {
      accountId: accountId.value,
      sub_page: channel,
    },
  });
};

const statusLabel = status => {
  switch (status) {
    case 'active':
      return t('LEAD_FORMS.STATUS.ACTIVE');
    case 'paused':
      return t('LEAD_FORMS.STATUS.PAUSED');
    case 'archived':
      return t('LEAD_FORMS.STATUS.ARCHIVED');
    case 'received':
      return t('LEAD_FORMS.STATUS.RECEIVED');
    case 'processed':
      return t('LEAD_FORMS.STATUS.PROCESSED');
    case 'failed':
      return t('LEAD_FORMS.STATUS.FAILED');
    default:
      return status;
  }
};

const endpointFor = form =>
  `${publicApiOrigin}/api/v1/lead_forms/${form.public_token}/submissions`;

const postEndpointFor = form => `POST ${endpointFor(form)}`;

const sampleValueFor = field => {
  switch (field.type) {
    case 'email':
      return 'client@example.com';
    case 'tel':
      return '+77001234567';
    case 'number':
      return 1;
    case 'date':
      return '2026-06-29';
    case 'url':
      return 'https://example.com';
    case 'select':
      return 'option_value';
    default:
      return field.placeholder || field.label || 'value';
  }
};

const sampleJsonFor = form => {
  const fields = Array.isArray(form.field_schema) ? form.field_schema : [];
  const fieldValues = fields.reduce((values, field) => {
    values[field.name] = sampleValueFor(field);
    return values;
  }, {});

  return JSON.stringify(
    {
      idempotency_key: `landing-${form.id}-001`,
      field_values: fieldValues,
      utm_source: 'website',
      utm_campaign: 'summer_campaign',
      landing_url: 'https://example.com/landing',
    },
    null,
    2
  );
};

watch(
  leadTargetInboxOptions,
  options => {
    if (!apiForm.inboxId && options[0]) {
      apiForm.inboxId = options[0].value;
    }
    if (!metaForm.inboxId && options[0]) {
      metaForm.inboxId = options[0].value;
    }
  },
  { immediate: true }
);

watch(
  metaConnectionOptions,
  options => {
    if (!selectedMetaConnectionId.value && options[0]) {
      selectedMetaConnectionId.value = options[0].value;
    }
  },
  { immediate: true }
);

watch(
  preferredPipelineId,
  defaultPipelineId => {
    if (!defaultPipelineId) return;
    if (!initializedDefaultPipeline.api) {
      apiForm.pipelineId = defaultPipelineId;
      apiForm.stageId = defaultStageIdForPipeline(defaultPipelineId);
      initializedDefaultPipeline.api = true;
    }
    if (!initializedDefaultPipeline.meta) {
      metaForm.pipelineId = defaultPipelineId;
      metaForm.stageId = defaultStageIdForPipeline(defaultPipelineId);
      initializedDefaultPipeline.meta = true;
    }
  },
  { immediate: true }
);

watch(
  () => apiForm.pipelineId,
  nextPipelineId => {
    if (!nextPipelineId) {
      apiForm.stageId = '';
      return;
    }
    const validStages = openStagesForPipeline(nextPipelineId);
    if (
      !validStages.some(stage => String(stage.id) === String(apiForm.stageId))
    ) {
      apiForm.stageId = defaultStageIdForPipeline(nextPipelineId);
    }
  }
);

watch(
  () => metaForm.pipelineId,
  nextPipelineId => {
    if (!nextPipelineId) {
      metaForm.stageId = '';
      return;
    }
    const validStages = openStagesForPipeline(nextPipelineId);
    if (
      !validStages.some(stage => String(stage.id) === String(metaForm.stageId))
    ) {
      metaForm.stageId = defaultStageIdForPipeline(nextPipelineId);
    }
  }
);

onMounted(loadPage);
</script>

<template>
  <main class="flex h-full min-h-0 flex-col overflow-y-auto bg-n-surface-1 p-6">
    <section class="w-full max-w-6xl mx-auto space-y-6">
      <header class="flex flex-col gap-4">
        <BaseSettingsHeader
          :title="$t('LEAD_FORMS.TITLE')"
          :description="$t('LEAD_FORMS.DESCRIPTION')"
          :back-button-label="$t('LEAD_FORMS.BACK_TO_PIPELINES')"
          :back-button-url="backToPipelinesRoute"
        />
        <TabBar
          active-text-class="text-n-slate-12 scale-100"
          :tabs="tabs"
          :initial-active-tab="activeTabIndex"
          @tab-changed="switchTab"
        />
      </header>

      <section v-if="activeTab === 'meta'" class="grid gap-4 lg:grid-cols-2">
        <article class="min-w-0">
          <div class="mb-5 flex items-start gap-3">
            <div
              class="flex size-11 shrink-0 items-center justify-center rounded-xl bg-n-brand/10 text-n-brand"
            >
              <span class="i-ri-meta-fill text-2xl" />
            </div>
            <div>
              <h2 class="text-heading-2 text-n-slate-12">
                {{ $t('LEAD_FORMS.META_FORMS.NEW_TITLE') }}
              </h2>
              <p class="mb-0 text-body-main text-n-slate-11">
                {{ $t('LEAD_FORMS.META_FORMS.NEW_DESCRIPTION') }}
              </p>
            </div>
          </div>

          <div
            v-if="!metaConnectionOptions.length"
            class="mb-5 rounded-xl bg-n-amber-3 p-4 outline outline-1 -outline-offset-1 outline-n-amber-6"
          >
            <h3 class="mb-1 text-sm font-semibold text-n-amber-12">
              {{ $t('LEAD_FORMS.META_FORMS.CONNECT_TITLE') }}
            </h3>
            <p class="mb-3 text-sm text-n-amber-11">
              {{ $t('LEAD_FORMS.META_FORMS.CONNECT_DESCRIPTION') }}
            </p>
            <div class="flex flex-wrap gap-2">
              <Button
                v-for="channel in metaRegistrationChannels"
                :key="channel.key"
                type="button"
                variant="secondary"
                size="sm"
                :icon="channel.icon"
                :label="channel.title"
                @click="openChannelRegistration(channel.key)"
              />
            </div>
          </div>

          <form class="space-y-4" @submit.prevent="createMetaForm">
            <div class="grid gap-3 md:grid-cols-2">
              <label class="space-y-1">
                <span class="text-sm font-medium text-n-slate-12">
                  {{ $t('LEAD_FORMS.META_FORMS.CONNECTION_LABEL') }}
                </span>
                <ComboBox
                  v-model="selectedMetaConnectionId"
                  :options="metaConnectionOptions"
                  :placeholder="$t('LEAD_FORMS.META_FORMS.SELECT_CONNECTION')"
                  :empty-state="$t('LEAD_FORMS.META_FORMS.NO_CONNECTIONS')"
                  input-like
                  :disabled="!metaConnectionOptions.length"
                />
              </label>
              <label class="space-y-1">
                <span class="text-sm font-medium text-n-slate-12">
                  {{ $t('LEAD_FORMS.META_FORMS.INBOX_LABEL') }}
                </span>
                <ComboBox
                  v-model="metaForm.inboxId"
                  :options="leadTargetInboxOptions"
                  :placeholder="$t('LEAD_FORMS.API_FORMS.SELECT_INBOX')"
                  :empty-state="$t('LEAD_FORMS.API_FORMS.NO_CHANNELS')"
                  input-like
                  :disabled="!leadTargetInboxOptions.length"
                />
              </label>
            </div>

            <div class="grid gap-3 md:grid-cols-2">
              <label
                class="space-y-1"
                data-testid="meta-form-pipeline-select"
              >
                <span class="text-sm font-medium text-n-slate-12">
                  {{ $t('LEAD_FORMS.PIPELINE_LABEL') }}
                </span>
                <ComboBox
                  v-model="metaForm.pipelineId"
                  :options="pipelineOptions"
                  :placeholder="$t('LEAD_FORMS.SELECT_PIPELINE')"
                  input-like
                />
              </label>
              <label
                v-if="metaForm.pipelineId"
                class="space-y-1"
                data-testid="meta-form-stage-select"
              >
                <span class="text-sm font-medium text-n-slate-12">
                  {{ $t('LEAD_FORMS.STAGE_LABEL') }}
                </span>
                <ComboBox
                  v-model="metaForm.stageId"
                  :options="stageOptionsForPipeline(metaForm.pipelineId)"
                  :placeholder="$t('LEAD_FORMS.SELECT_STAGE')"
                  input-like
                />
              </label>
            </div>

            <label class="block space-y-1">
              <span class="text-sm font-medium text-n-slate-12">
                {{ $t('LEAD_FORMS.META_FORMS.NAME_LABEL') }}
              </span>
              <Input
                v-model="metaForm.name"
                :placeholder="$t('LEAD_FORMS.META_FORMS.NAME_PLACEHOLDER')"
              />
            </label>
            <div class="grid gap-3 md:grid-cols-2">
              <label class="space-y-1">
                <span class="text-sm font-medium text-n-slate-12">
                  {{ $t('LEAD_FORMS.META_FORMS.FORM_ID_LABEL') }}
                </span>
                <Input
                  v-model="metaForm.metaFormId"
                  :placeholder="$t('LEAD_FORMS.META_FORMS.FORM_ID_PLACEHOLDER')"
                />
              </label>
              <label class="space-y-1">
                <span class="text-sm font-medium text-n-slate-12">
                  {{ $t('LEAD_FORMS.META_FORMS.PAGE_ID_LABEL') }}
                </span>
                <Input
                  v-model="metaForm.metaPageId"
                  :placeholder="$t('LEAD_FORMS.META_FORMS.PAGE_ID_PLACEHOLDER')"
                />
              </label>
            </div>
            <label class="block space-y-1">
              <span class="text-sm font-medium text-n-slate-12">
                {{ $t('LEAD_FORMS.META_FORMS.VERIFY_TOKEN_LABEL') }}
              </span>
              <Input
                v-model="metaForm.verifyToken"
                :placeholder="
                  $t('LEAD_FORMS.META_FORMS.VERIFY_TOKEN_PLACEHOLDER')
                "
              />
            </label>
            <p class="mb-0 text-sm text-n-slate-11">
              {{ $t('LEAD_FORMS.META_FORMS.WEBHOOK_NOTE') }}
              <code class="rounded bg-n-alpha-2 px-2 py-1 text-xs">
                {{ $t('LEAD_FORMS.META_FORMS.WEBHOOK_PATH') }}
              </code>
            </p>
            <div class="flex justify-end">
              <Button
                type="submit"
                :label="$t('LEAD_FORMS.CREATE')"
                :disabled="
                  !metaConnectionOptions.length ||
                  !leadTargetInboxOptions.length
                "
                :is-loading="savingSource === 'meta'"
              />
            </div>
          </form>
        </article>

        <article class="min-w-0">
          <h2 class="text-heading-2 text-n-slate-12">
            {{ $t('LEAD_FORMS.META_FORMS.LIST_TITLE') }}
          </h2>
          <div
            class="mt-3 divide-y divide-n-weak rounded-xl outline outline-1 -outline-offset-1 outline-n-weak"
          >
            <p
              v-if="!metaForms.length"
              class="mb-0 px-4 py-3 text-sm text-n-slate-11"
            >
              {{ $t('LEAD_FORMS.META_FORMS.EMPTY') }}
            </p>
            <div
              v-for="form in metaForms"
              :key="form.id"
              class="space-y-3 px-4 py-3"
            >
              <div>
                <p class="mb-0 font-medium text-n-slate-12">{{ form.name }}</p>
                <p class="mb-0 text-xs text-n-slate-11">
                  {{ form.external_ref || form.settings?.meta_form_id }}
                  {{ $t('LEAD_FORMS.SEPARATOR') }}
                  {{ form.inbox_name || `Inbox #${form.inbox_id}` }}
                  <template v-if="form.pipeline_name">
                    {{ $t('LEAD_FORMS.SEPARATOR') }}
                    {{ form.pipeline_name }}
                    <template v-if="form.stage_name">
                      ({{ form.stage_name }})
                    </template>
                  </template>
                  {{ $t('LEAD_FORMS.SEPARATOR') }}
                  {{ statusLabel(form.status) }}
                </p>
              </div>
              <div
                v-if="activePipelines.length"
                class="grid gap-3 md:grid-cols-2"
              >
                <label class="space-y-1">
                  <span class="text-xs font-medium text-n-slate-11">
                    {{ $t('LEAD_FORMS.PIPELINE_LABEL') }}
                  </span>
                  <ComboBox
                    :model-value="
                      form.pipeline_id ? String(form.pipeline_id) : ''
                    "
                    :options="pipelineOptions"
                    :placeholder="$t('LEAD_FORMS.SELECT_PIPELINE')"
                    :disabled="updatingFormId === form.id"
                    input-like
                    @update:model-value="updateFormPipeline(form, $event)"
                  />
                </label>
                <label v-if="form.pipeline_id" class="space-y-1">
                  <span class="text-xs font-medium text-n-slate-11">
                    {{ $t('LEAD_FORMS.STAGE_LABEL') }}
                  </span>
                  <ComboBox
                    :model-value="form.stage_id ? String(form.stage_id) : ''"
                    :options="stageOptionsForPipeline(form.pipeline_id)"
                    :placeholder="$t('LEAD_FORMS.SELECT_STAGE')"
                    :disabled="updatingFormId === form.id"
                    input-like
                    @update:model-value="updateFormStage(form, $event)"
                  />
                </label>
              </div>
            </div>
          </div>
        </article>
      </section>

      <section v-if="activeTab === 'api'" class="grid gap-4 lg:grid-cols-2">
        <article class="min-w-0 lg:col-span-2">
          <div class="mb-5 flex items-start gap-3">
            <div
              class="flex size-11 shrink-0 items-center justify-center rounded-xl bg-n-brand/10 text-n-brand"
            >
              <span class="i-lucide-form-input text-2xl" />
            </div>
            <div>
              <h2 class="text-heading-2 text-n-slate-12">
                {{ $t('LEAD_FORMS.API_FORMS.NEW_TITLE') }}
              </h2>
              <p class="mb-0 text-body-main text-n-slate-11">
                {{ $t('LEAD_FORMS.API_FORMS.NEW_DESCRIPTION') }}
              </p>
            </div>
          </div>

          <form class="space-y-5" @submit.prevent="createApiForm">
            <div class="grid gap-3 md:grid-cols-2">
              <label class="space-y-1">
                <span class="text-sm font-medium text-n-slate-12">
                  {{ $t('LEAD_FORMS.API_FORMS.NAME_LABEL') }}
                </span>
                <Input
                  v-model="apiForm.name"
                  :placeholder="$t('LEAD_FORMS.API_FORMS.NAME_PLACEHOLDER')"
                />
              </label>
              <label class="space-y-1">
                <span class="text-sm font-medium text-n-slate-12">
                  {{ $t('LEAD_FORMS.API_FORMS.INBOX_LABEL') }}
                </span>
                <ComboBox
                  v-model="apiForm.inboxId"
                  :options="leadTargetInboxOptions"
                  :placeholder="$t('LEAD_FORMS.API_FORMS.SELECT_INBOX')"
                  :empty-state="$t('LEAD_FORMS.API_FORMS.NO_CHANNELS')"
                  input-like
                  :disabled="!leadTargetInboxOptions.length"
                />
              </label>
            </div>

            <div class="grid gap-3 md:grid-cols-2">
              <label
                class="space-y-1"
                data-testid="api-form-pipeline-select"
              >
                <span class="text-sm font-medium text-n-slate-12">
                  {{ $t('LEAD_FORMS.PIPELINE_LABEL') }}
                </span>
                <ComboBox
                  v-model="apiForm.pipelineId"
                  :options="pipelineOptions"
                  :placeholder="$t('LEAD_FORMS.SELECT_PIPELINE')"
                  input-like
                />
              </label>
              <label
                v-if="apiForm.pipelineId"
                class="space-y-1"
                data-testid="api-form-stage-select"
              >
                <span class="text-sm font-medium text-n-slate-12">
                  {{ $t('LEAD_FORMS.STAGE_LABEL') }}
                </span>
                <ComboBox
                  v-model="apiForm.stageId"
                  :options="stageOptionsForPipeline(apiForm.pipelineId)"
                  :placeholder="$t('LEAD_FORMS.SELECT_STAGE')"
                  input-like
                />
              </label>
            </div>

            <p
              v-if="!leadTargetInboxOptions.length"
              class="mb-0 rounded-xl bg-n-amber-3 p-3 text-sm text-n-amber-11 outline outline-1 -outline-offset-1 outline-n-amber-6"
            >
              {{ $t('LEAD_FORMS.API_FORMS.NO_CHANNELS') }}
            </p>

            <div class="flex items-center my-6 py-1">
              <div class="flex-1 h-px bg-n-weak" />
              <span class="px-2 text-body-main text-n-slate-11">
                {{ $t('INBOX_MGMT.PRE_CHAT_FORM.SET_FIELDS') }}
              </span>
              <div class="flex-1 h-px bg-n-weak" />
            </div>

            <ApiFieldBuilder v-model:fields="apiFormFields" />

            <div class="flex justify-end">
              <Button
                type="submit"
                :label="$t('LEAD_FORMS.CREATE')"
                :disabled="!leadTargetInboxOptions.length"
                :is-loading="savingSource === 'api'"
              />
            </div>
          </form>
        </article>

        <article class="min-w-0 lg:col-span-2">
          <h2 class="text-heading-2 text-n-slate-12">
            {{ $t('LEAD_FORMS.API_FORMS.LIST_TITLE') }}
          </h2>
          <div
            class="mt-3 divide-y divide-n-weak rounded-xl outline outline-1 -outline-offset-1 outline-n-weak"
          >
            <p
              v-if="!apiForms.length"
              class="mb-0 px-4 py-3 text-sm text-n-slate-11"
            >
              {{ $t('LEAD_FORMS.EMPTY') }}
            </p>
            <div
              v-for="form in apiForms"
              :key="form.id"
              class="space-y-3 px-4 py-3"
            >
              <div class="flex items-start justify-between gap-4">
                <div>
                  <p class="mb-0 font-medium text-n-slate-12">
                    {{ form.name }}
                  </p>
                  <p class="mb-0 text-xs text-n-slate-11">
                    {{ form.inbox_name || `Inbox #${form.inbox_id}` }}
                    <template v-if="form.pipeline_name">
                      {{ $t('LEAD_FORMS.SEPARATOR') }}
                      {{ form.pipeline_name }}
                      <template v-if="form.stage_name">
                        ({{ form.stage_name }})
                      </template>
                    </template>
                    {{ $t('LEAD_FORMS.SEPARATOR') }}
                    {{ statusLabel(form.status) }}
                  </p>
                </div>
              </div>
              <div
                v-if="activePipelines.length"
                class="grid gap-3 md:grid-cols-2"
              >
                <label class="space-y-1">
                  <span class="text-xs font-medium text-n-slate-11">
                    {{ $t('LEAD_FORMS.PIPELINE_LABEL') }}
                  </span>
                  <ComboBox
                    :model-value="
                      form.pipeline_id ? String(form.pipeline_id) : ''
                    "
                    :options="pipelineOptions"
                    :placeholder="$t('LEAD_FORMS.SELECT_PIPELINE')"
                    :disabled="updatingFormId === form.id"
                    input-like
                    @update:model-value="updateFormPipeline(form, $event)"
                  />
                </label>
                <label v-if="form.pipeline_id" class="space-y-1">
                  <span class="text-xs font-medium text-n-slate-11">
                    {{ $t('LEAD_FORMS.STAGE_LABEL') }}
                  </span>
                  <ComboBox
                    :model-value="form.stage_id ? String(form.stage_id) : ''"
                    :options="stageOptionsForPipeline(form.pipeline_id)"
                    :placeholder="$t('LEAD_FORMS.SELECT_STAGE')"
                    :disabled="updatingFormId === form.id"
                    input-like
                    @update:model-value="updateFormStage(form, $event)"
                  />
                </label>
              </div>
              <div class="space-y-2">
                <p class="mb-0 text-xs font-medium uppercase text-n-slate-10">
                  {{ $t('LEAD_FORMS.API_FORMS.ENDPOINT_TITLE') }}
                </p>
                <code class="block break-all bg-n-alpha-2 px-2 py-1 text-xs">
                  {{ postEndpointFor(form) }}
                </code>
                <p class="mb-0 text-xs font-medium uppercase text-n-slate-10">
                  {{ $t('LEAD_FORMS.API_FORMS.TOKEN_LABEL') }}
                </p>
                <code class="block break-all bg-n-alpha-2 px-2 py-1 text-xs">
                  {{ form.public_token }}
                </code>
                <p class="mb-0 text-xs font-medium uppercase text-n-slate-10">
                  {{ $t('LEAD_FORMS.API_FORMS.JSON_EXAMPLE') }}
                </p>
                <pre
                  class="max-h-72 overflow-auto bg-n-alpha-2 p-3 text-xs text-n-slate-12"
                ><code>{{ sampleJsonFor(form) }}</code></pre>
              </div>
            </div>
          </div>
        </article>
      </section>
    </section>
  </main>
</template>
