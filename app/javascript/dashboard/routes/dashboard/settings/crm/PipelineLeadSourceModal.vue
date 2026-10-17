<script setup>
import { computed, reactive, ref, watch } from 'vue';
import { useI18n } from 'vue-i18n';
import { useRoute, useRouter } from 'vue-router';
import { useStore } from 'vuex';
import { useMapGetter } from 'dashboard/composables/store';
import { useAlert } from 'dashboard/composables';
import Button from 'dashboard/components-next/button/Button.vue';
import ComboBox from 'dashboard/components-next/combobox/ComboBox.vue';
import Input from 'dashboard/components-next/input/Input.vue';
import SchedulingDrawer from 'dashboard/components-next/Scheduling/SchedulingDrawer.vue';
import { getInboxFlowRouteName } from 'dashboard/routes/dashboard/settings/inbox/helpers/inboxFlowRoutes';
import leadFormsAPI from 'dashboard/api/leadForms';
import { getInboxIconByType, INBOX_TYPES } from 'dashboard/helper/inbox';
import ApiFieldBuilder from '../leadForms/ApiFieldBuilder.vue';
import {
  isTechnicalStage,
  isTerminalStageOutcome,
  sortStages,
} from './stageOrder';
import { dealStageDisplayName } from 'dashboard/components-next/CRM/dealStageSelection';

const props = defineProps({
  modelValue: {
    type: Boolean,
    default: false,
  },
  sourceKind: {
    type: String,
    default: 'meta',
    validator: value => ['meta', 'api'].includes(value),
  },
  pipeline: {
    type: Object,
    default: null,
  },
  forms: {
    type: Array,
    default: () => [],
  },
});

const emit = defineEmits(['update:modelValue', 'updated']);

const { t } = useI18n();
const route = useRoute();
const router = useRouter();
const store = useStore();

const saving = ref(false);
const updatingFormId = ref(null);
const showCreateForm = ref(false);
const expandedApiFormId = ref(null);
const selectedMetaConnectionId = ref('');

const apiForm = reactive({
  name: '',
  inboxId: '',
  stageId: '',
});

const metaForm = reactive({
  name: '',
  inboxId: '',
  stageId: '',
  metaFormId: '',
  metaPageId: '',
  verifyToken: '',
});

const inboxes = useMapGetter('inboxes/getInboxes');
const accountId = computed(() => route.params.accountId);
const publicApiOrigin =
  typeof window !== 'undefined' ? window.location.origin : '';

const openStages = computed(() =>
  sortStages(props.pipeline?.stages || []).filter(
    stage =>
      stage.active !== false &&
      !isTechnicalStage(stage) &&
      !isTerminalStageOutcome(stage.outcome)
  )
);

const stageOptions = computed(() =>
  openStages.value.map(stage => ({
    value: String(stage.id),
    label: dealStageDisplayName(stage, t),
  }))
);

const defaultStageId = computed(() => {
  const preferred =
    openStages.value.find(stage => stage.default) || openStages.value[0];
  return preferred ? String(preferred.id) : '';
});

const sourceForms = computed(() =>
  (props.forms || []).filter(form => form.source_kind === props.sourceKind)
);

const pipelineForms = computed(() =>
  sourceForms.value.filter(
    form =>
      props.pipeline?.id &&
      Number(form.pipeline_id) === Number(props.pipeline.id)
  )
);

const unassignedForms = computed(() =>
  sourceForms.value.filter(
    form =>
      !props.pipeline?.id ||
      Number(form.pipeline_id) !== Number(props.pipeline.id)
  )
);

const modalTitle = computed(() => {
  const pipelineName = props.pipeline?.name || '';
  if (props.sourceKind === 'meta') {
    return pipelineName
      ? `${t('CRM.SETTINGS.PIPELINES.META_LEAD_FORMS_TITLE')} — ${pipelineName}`
      : t('CRM.SETTINGS.PIPELINES.META_LEAD_FORMS_TITLE');
  }
  return pipelineName
    ? `${t('CRM.SETTINGS.PIPELINES.API_LEAD_FORMS_TITLE')} — ${pipelineName}`
    : t('CRM.SETTINGS.PIPELINES.API_LEAD_FORMS_TITLE');
});

const modalDescription = computed(() =>
  props.sourceKind === 'meta'
    ? t('CRM.SETTINGS.PIPELINES.META_LEAD_FORMS_MODAL_DESCRIPTION')
    : t('CRM.SETTINGS.PIPELINES.API_LEAD_FORMS_MODAL_DESCRIPTION')
);

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
  (inboxes.value || [])
    .filter(inbox => !excludedLeadTargetInboxTypes.has(inbox.channel_type))
    .sort((a, b) => a.name.localeCompare(b.name))
    .map(inboxOption)
);

const metaConnectionOptions = computed(() =>
  (inboxes.value || [])
    .filter(inbox => metaRegistrationInboxTypes.has(inbox.channel_type))
    .sort((a, b) => a.name.localeCompare(b.name))
    .map(inboxOption)
);

const selectedMetaConnection = computed(() =>
  (inboxes.value || []).find(
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

const syncDefaults = () => {
  if (!apiForm.inboxId && leadTargetInboxOptions.value[0]) {
    apiForm.inboxId = leadTargetInboxOptions.value[0].value;
  }
  if (!metaForm.inboxId && leadTargetInboxOptions.value[0]) {
    metaForm.inboxId = leadTargetInboxOptions.value[0].value;
  }
  if (!selectedMetaConnectionId.value && metaConnectionOptions.value[0]) {
    selectedMetaConnectionId.value = metaConnectionOptions.value[0].value;
  }
  if (
    !apiForm.stageId ||
    !openStages.value.some(
      stage => String(stage.id) === String(apiForm.stageId)
    )
  ) {
    apiForm.stageId = defaultStageId.value;
  }
  if (
    !metaForm.stageId ||
    !openStages.value.some(
      stage => String(stage.id) === String(metaForm.stageId)
    )
  ) {
    metaForm.stageId = defaultStageId.value;
  }
};

const loadInboxesIfNeeded = () => {
  if ((inboxes.value || []).length) return;
  store?.dispatch?.('inboxes/get')?.catch?.(() => {});
};

watch(
  () => [
    props.modelValue,
    props.sourceKind,
    props.pipeline?.id,
    leadTargetInboxOptions.value.length,
    metaConnectionOptions.value.length,
  ],
  () => {
    if (!props.modelValue) return;
    loadInboxesIfNeeded();
    syncDefaults();
    showCreateForm.value = pipelineForms.value.length === 0;
  },
  { immediate: true }
);

watch(
  () => pipelineForms.value.length,
  count => {
    if (count === 0) {
      showCreateForm.value = true;
    }
  }
);

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

  saving.value = true;
  try {
    const response = await leadFormsAPI.create({
      name: apiForm.name,
      inbox_id: Number(apiForm.inboxId),
      pipeline_id: props.pipeline?.id ? Number(props.pipeline.id) : null,
      stage_id: apiForm.stageId ? Number(apiForm.stageId) : null,
      source_kind: 'api',
      status: 'active',
      field_schema: fieldSchema,
      settings: {
        conversation_status: 'open',
        auth_mode: 'public_token',
      },
    });
    apiForm.name = '';
    apiFormFields.value = defaultApiFormFields();
    showCreateForm.value = false;
    if (response?.data?.id) {
      expandedApiFormId.value = response.data.id;
    }
    useAlert(t('LEAD_FORMS.CREATED'));
    emit('updated');
  } catch (error) {
    useAlert(t('LEAD_FORMS.ERRORS.SAVE'));
  } finally {
    saving.value = false;
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

  saving.value = true;
  try {
    await leadFormsAPI.create({
      name: metaForm.name,
      inbox_id: Number(metaForm.inboxId),
      pipeline_id: props.pipeline?.id ? Number(props.pipeline.id) : null,
      stage_id: metaForm.stageId ? Number(metaForm.stageId) : null,
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
    showCreateForm.value = false;
    useAlert(t('LEAD_FORMS.CREATED'));
    emit('updated');
  } catch (error) {
    useAlert(t('LEAD_FORMS.ERRORS.SAVE'));
  } finally {
    saving.value = false;
  }
};

const updateFormStage = async (form, nextStageId) => {
  if (!props.pipeline?.id) return;
  updatingFormId.value = form.id;
  try {
    await leadFormsAPI.update(form.id, {
      pipeline_id: Number(props.pipeline.id),
      stage_id: nextStageId ? Number(nextStageId) : null,
    });
    useAlert(t('LEAD_FORMS.UPDATED'));
    emit('updated');
  } catch (error) {
    useAlert(t('LEAD_FORMS.ERRORS.SAVE'));
  } finally {
    updatingFormId.value = null;
  }
};

const attachFormToPipeline = async form => {
  if (!props.pipeline?.id) return;
  updatingFormId.value = form.id;
  try {
    await leadFormsAPI.update(form.id, {
      pipeline_id: Number(props.pipeline.id),
      stage_id: defaultStageId.value ? Number(defaultStageId.value) : null,
    });
    useAlert(t('LEAD_FORMS.UPDATED'));
    emit('updated');
  } catch (error) {
    useAlert(t('LEAD_FORMS.ERRORS.SAVE'));
  } finally {
    updatingFormId.value = null;
  }
};

const detachFormFromPipeline = async form => {
  updatingFormId.value = form.id;
  try {
    await leadFormsAPI.update(form.id, {
      pipeline_id: null,
      stage_id: null,
    });
    useAlert(t('LEAD_FORMS.UPDATED'));
    emit('updated');
  } catch (error) {
    useAlert(t('LEAD_FORMS.ERRORS.SAVE'));
  } finally {
    updatingFormId.value = null;
  }
};

const openChannelRegistration = channel => {
  emit('update:modelValue', false);
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
    default:
      return status;
  }
};

const postEndpointFor = form =>
  `${publicApiOrigin}/public/api/v1/lead_forms/${form.public_token}/submissions`;

const sampleValueFor = field => {
  if (isPhoneField(field) || field.type === 'tel') return '+77015550101';
  if (field.type === 'email') return 'client@example.com';
  if (field.type === 'number') return 1;
  if (field.type === 'date') return '2026-04-14';
  if (field.type === 'url') return 'https://example.com';
  return field.placeholder || field.label || field.name;
};

const sampleJsonFor = form => {
  const fields = form.field_schema?.length
    ? form.field_schema
    : defaultApiFormFields();
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
</script>

<template>
  <SchedulingDrawer
    :model-value="modelValue"
    placement="center"
    width="xl"
    :title="modalTitle"
    :description="modalDescription"
    :confirm-label="$t('CRM.GENERAL.CLOSE')"
    @update:model-value="emit('update:modelValue', $event)"
    @confirm="emit('update:modelValue', false)"
  >
    <div class="grid gap-5" data-testid="pipeline-lead-source-modal">
      <!-- Connected forms for the current pipeline -->
      <section class="grid gap-3">
        <div class="flex items-center justify-between gap-3">
          <div class="flex items-center gap-2">
            <h3 class="mb-0 text-sm font-semibold text-n-slate-12">
              {{ $t('CRM.SETTINGS.PIPELINES.CONNECTED_FORMS_TITLE') }}
            </h3>
            <span
              class="inline-flex h-5 min-w-5 items-center justify-center rounded-full bg-n-alpha-2 px-1.5 text-xs font-medium text-n-slate-11"
            >
              {{ pipelineForms.length }}
            </span>
          </div>
          <Button
            v-if="!showCreateForm"
            type="button"
            size="xs"
            color="blue"
            variant="faded"
            icon="i-lucide-plus"
            :label="$t('LEAD_FORMS.CREATE')"
            data-testid="toggle-create-lead-form-btn"
            @click="showCreateForm = true"
          />
        </div>

        <p
          v-if="!pipelineForms.length && !showCreateForm"
          class="mb-0 rounded-xl border border-dashed border-n-weak px-4 py-3 text-sm text-n-slate-10"
        >
          {{ $t('CRM.SETTINGS.PIPELINES.NO_CONNECTED_FORMS') }}
        </p>

        <div
          v-if="pipelineForms.length"
          class="divide-y divide-n-weak rounded-xl border border-n-weak bg-n-solid-2"
        >
          <div
            v-for="form in pipelineForms"
            :key="form.id"
            class="grid gap-3 p-4"
            :data-testid="`connected-lead-form-${form.id}`"
          >
            <div class="flex flex-wrap items-start justify-between gap-3">
              <div class="min-w-0">
                <div class="flex items-center gap-2">
                  <span class="font-medium text-n-slate-12">
                    {{ form.name }}
                  </span>
                  <span
                    class="rounded-md bg-n-teal-3 px-2 py-0.5 text-xs font-medium text-n-teal-11"
                  >
                    {{ statusLabel(form.status) }}
                  </span>
                </div>
                <p class="mb-0 mt-0.5 text-xs text-n-slate-10">
                  {{ form.inbox_name || `Inbox #${form.inbox_id}` }}
                  <template v-if="sourceKind === 'meta' && form.external_ref">
                    {{ $t('LEAD_FORMS.SEPARATOR') }}
                    {{
                      `${$t('LEAD_FORMS.META_FORMS.FORM_ID_LABEL')}: ${form.external_ref}`
                    }}
                  </template>
                </p>
              </div>

              <div class="flex items-center gap-2">
                <Button
                  v-if="sourceKind === 'api'"
                  type="button"
                  size="xs"
                  color="slate"
                  variant="faded"
                  icon="i-lucide-code-2"
                  :label="$t('LEAD_FORMS.API_FORMS.ENDPOINT_TITLE')"
                  @click="
                    expandedApiFormId =
                      expandedApiFormId === form.id ? null : form.id
                  "
                />
                <Button
                  type="button"
                  size="xs"
                  color="slate"
                  variant="ghost"
                  icon="i-lucide-unlink"
                  :title="$t('CRM.SETTINGS.PIPELINES.DETACH_FORM')"
                  :disabled="updatingFormId === form.id"
                  @click="detachFormFromPipeline(form)"
                />
              </div>
            </div>

            <div class="grid gap-1 sm:max-w-xs">
              <span class="text-xs font-medium text-n-slate-11">
                {{ $t('LEAD_FORMS.STAGE_LABEL') }}
              </span>
              <ComboBox
                :model-value="form.stage_id ? String(form.stage_id) : ''"
                :options="stageOptions"
                :placeholder="$t('LEAD_FORMS.SELECT_STAGE')"
                :disabled="updatingFormId === form.id"
                input-like
                @update:model-value="updateFormStage(form, $event)"
              />
            </div>

            <div
              v-if="sourceKind === 'api' && expandedApiFormId === form.id"
              class="grid gap-2 rounded-xl bg-n-surface-1 p-3 outline outline-1 outline-n-weak"
            >
              <p class="mb-0 text-xs font-medium uppercase text-n-slate-10">
                {{ $t('LEAD_FORMS.API_FORMS.ENDPOINT_TITLE') }}
              </p>
              <code
                class="block break-all rounded bg-n-alpha-2 px-2 py-1 text-xs"
              >
                {{ postEndpointFor(form) }}
              </code>
              <p class="mb-0 text-xs font-medium uppercase text-n-slate-10">
                {{ $t('LEAD_FORMS.API_FORMS.TOKEN_LABEL') }}
              </p>
              <code
                class="block break-all rounded bg-n-alpha-2 px-2 py-1 text-xs"
              >
                {{ form.public_token }}
              </code>
              <p class="mb-0 text-xs font-medium uppercase text-n-slate-10">
                {{ $t('LEAD_FORMS.API_FORMS.JSON_EXAMPLE') }}
              </p>
              <pre
                class="mb-0 max-h-48 overflow-auto rounded bg-n-alpha-2 p-2.5 text-xs text-n-slate-12"
              ><code>{{ sampleJsonFor(form) }}</code></pre>
            </div>
          </div>
        </div>
      </section>

      <!-- Existing unassigned forms that can be bound in 1 click -->
      <section v-if="unassignedForms.length" class="grid gap-2">
        <h4
          class="mb-0 text-xs font-semibold uppercase tracking-wide text-n-slate-10"
        >
          {{ $t('CRM.SETTINGS.PIPELINES.OTHER_ACCOUNT_FORMS_TITLE') }}
        </h4>
        <div
          class="divide-y divide-n-weak rounded-xl border border-n-weak bg-n-surface-1"
        >
          <div
            v-for="form in unassignedForms"
            :key="form.id"
            class="flex items-center justify-between gap-3 px-4 py-2.5"
          >
            <div class="min-w-0">
              <p class="mb-0 truncate text-sm font-medium text-n-slate-12">
                {{ form.name }}
              </p>
              <p class="mb-0 text-xs text-n-slate-10">
                {{ form.inbox_name || `Inbox #${form.inbox_id}` }}
                <template v-if="form.pipeline_name">
                  {{ $t('LEAD_FORMS.SEPARATOR') }}
                  {{ form.pipeline_name }}
                </template>
              </p>
            </div>
            <Button
              type="button"
              size="xs"
              color="slate"
              variant="faded"
              icon="i-lucide-link"
              :label="$t('CRM.SETTINGS.PIPELINES.ATTACH_TO_PIPELINE')"
              :disabled="updatingFormId === form.id"
              @click="attachFormToPipeline(form)"
            />
          </div>
        </div>
      </section>

      <!-- Create new form bound to the current pipeline -->
      <section
        v-if="showCreateForm"
        class="grid gap-4 rounded-2xl border border-n-weak bg-n-solid-2 p-5"
        data-testid="create-lead-form-section"
      >
        <div class="flex items-center justify-between gap-3">
          <div class="flex items-center gap-2.5">
            <span
              :class="
                sourceKind === 'meta'
                  ? 'i-ri-meta-fill size-5 text-n-brand'
                  : 'i-lucide-webhook size-5 text-n-brand'
              "
            />
            <h3 class="mb-0 text-sm font-semibold text-n-slate-12">
              {{
                sourceKind === 'meta'
                  ? $t('LEAD_FORMS.META_FORMS.NEW_TITLE')
                  : $t('LEAD_FORMS.API_FORMS.NEW_TITLE')
              }}
            </h3>
          </div>
          <Button
            v-if="pipelineForms.length"
            type="button"
            size="xs"
            color="slate"
            variant="ghost"
            :label="$t('CRM.GENERAL.CANCEL')"
            @click="showCreateForm = false"
          />
        </div>

        <!-- META LEAD ADS CREATION FORM -->
        <template v-if="sourceKind === 'meta'">
          <div
            v-if="!metaConnectionOptions.length"
            class="rounded-xl bg-n-amber-3 p-4 outline outline-1 -outline-offset-1 outline-n-amber-6"
          >
            <h4 class="mb-1 text-sm font-semibold text-n-amber-12">
              {{ $t('LEAD_FORMS.META_FORMS.CONNECT_TITLE') }}
            </h4>
            <p class="mb-3 text-xs leading-5 text-n-amber-11">
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

          <form class="grid gap-4" @submit.prevent="createMetaForm">
            <div class="grid gap-3 md:grid-cols-2">
              <label class="space-y-1">
                <span class="text-xs font-medium text-n-slate-12">
                  {{ $t('LEAD_FORMS.META_FORMS.NAME_LABEL') }}
                </span>
                <Input
                  v-model="metaForm.name"
                  :placeholder="$t('LEAD_FORMS.META_FORMS.NAME_PLACEHOLDER')"
                />
              </label>
              <label class="space-y-1" data-testid="modal-meta-stage-select">
                <span class="text-xs font-medium text-n-slate-12">
                  {{ $t('LEAD_FORMS.STAGE_LABEL') }}
                </span>
                <ComboBox
                  v-model="metaForm.stageId"
                  :options="stageOptions"
                  :placeholder="$t('LEAD_FORMS.SELECT_STAGE')"
                  input-like
                />
              </label>
            </div>

            <div class="grid gap-3 md:grid-cols-2">
              <label class="space-y-1">
                <span class="text-xs font-medium text-n-slate-12">
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
                <span class="text-xs font-medium text-n-slate-12">
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

            <div class="grid gap-3 md:grid-cols-3">
              <label class="space-y-1">
                <span class="text-xs font-medium text-n-slate-12">
                  {{ $t('LEAD_FORMS.META_FORMS.FORM_ID_LABEL') }}
                </span>
                <Input
                  v-model="metaForm.metaFormId"
                  :placeholder="$t('LEAD_FORMS.META_FORMS.FORM_ID_PLACEHOLDER')"
                />
              </label>
              <label class="space-y-1">
                <span class="text-xs font-medium text-n-slate-12">
                  {{ $t('LEAD_FORMS.META_FORMS.PAGE_ID_LABEL') }}
                </span>
                <Input
                  v-model="metaForm.metaPageId"
                  :placeholder="$t('LEAD_FORMS.META_FORMS.PAGE_ID_PLACEHOLDER')"
                />
              </label>
              <label class="space-y-1">
                <span class="text-xs font-medium text-n-slate-12">
                  {{ $t('LEAD_FORMS.META_FORMS.VERIFY_TOKEN_LABEL') }}
                </span>
                <Input
                  v-model="metaForm.verifyToken"
                  :placeholder="
                    $t('LEAD_FORMS.META_FORMS.VERIFY_TOKEN_PLACEHOLDER')
                  "
                />
              </label>
            </div>

            <div class="flex flex-wrap items-center justify-between gap-3">
              <p class="mb-0 text-xs text-n-slate-11">
                {{ $t('LEAD_FORMS.META_FORMS.WEBHOOK_NOTE') }}
                <code class="rounded bg-n-alpha-2 px-2 py-0.5 text-xs">
                  {{ $t('LEAD_FORMS.META_FORMS.WEBHOOK_PATH') }}
                </code>
              </p>
              <Button
                type="submit"
                size="sm"
                :label="$t('LEAD_FORMS.CREATE')"
                :disabled="
                  !metaConnectionOptions.length ||
                  !leadTargetInboxOptions.length
                "
                :is-loading="saving"
              />
            </div>
          </form>
        </template>

        <!-- API / WEBSITE FORM CREATION -->
        <template v-else>
          <form class="grid gap-4" @submit.prevent="createApiForm">
            <div class="grid gap-3 md:grid-cols-3">
              <label class="space-y-1">
                <span class="text-xs font-medium text-n-slate-12">
                  {{ $t('LEAD_FORMS.API_FORMS.NAME_LABEL') }}
                </span>
                <Input
                  v-model="apiForm.name"
                  :placeholder="$t('LEAD_FORMS.API_FORMS.NAME_PLACEHOLDER')"
                />
              </label>
              <label class="space-y-1" data-testid="modal-api-stage-select">
                <span class="text-xs font-medium text-n-slate-12">
                  {{ $t('LEAD_FORMS.STAGE_LABEL') }}
                </span>
                <ComboBox
                  v-model="apiForm.stageId"
                  :options="stageOptions"
                  :placeholder="$t('LEAD_FORMS.SELECT_STAGE')"
                  input-like
                />
              </label>
              <label class="space-y-1">
                <span class="text-xs font-medium text-n-slate-12">
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

            <p
              v-if="!leadTargetInboxOptions.length"
              class="mb-0 rounded-xl bg-n-amber-3 p-3 text-xs text-n-amber-11 outline outline-1 -outline-offset-1 outline-n-amber-6"
            >
              {{ $t('LEAD_FORMS.API_FORMS.NO_CHANNELS') }}
            </p>

            <ApiFieldBuilder v-model:fields="apiFormFields" />

            <div class="flex justify-end">
              <Button
                type="submit"
                size="sm"
                :label="$t('LEAD_FORMS.CREATE')"
                :disabled="!leadTargetInboxOptions.length"
                :is-loading="saving"
              />
            </div>
          </form>
        </template>
      </section>
    </div>
  </SchedulingDrawer>
</template>
