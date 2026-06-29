<script setup>
import { computed, onMounted, reactive, ref, watch } from 'vue';
import { useI18n } from 'vue-i18n';
import { useRoute, useRouter } from 'vue-router';
import { useStore } from 'vuex';
import { useMapGetter } from 'dashboard/composables/store';
import { useAlert } from 'dashboard/composables';
import Button from 'dashboard/components-next/button/Button.vue';
import ComboBox from 'dashboard/components-next/combobox/ComboBox.vue';
import PreChatFormSettings from 'dashboard/routes/dashboard/settings/inbox/PreChatForm/Settings.vue';
import { getInboxFlowRouteName } from 'dashboard/routes/dashboard/settings/inbox/helpers/inboxFlowRoutes';
import leadFormsAPI from 'dashboard/api/leadForms';
import leadSubmissionsAPI from 'dashboard/api/leadSubmissions';
import { getInboxIconByType, INBOX_TYPES } from 'dashboard/helper/inbox';
import ApiFieldBuilder from './ApiFieldBuilder.vue';

const { t } = useI18n();
const route = useRoute();
const router = useRouter();
const store = useStore();

const forms = ref([]);
const submissions = ref([]);
const isLoading = ref(false);
const savingSource = ref('');
const activeTab = ref('meta');
const selectedWidgetInboxId = ref('');
const selectedMetaConnectionId = ref('');
const apiForm = reactive({ name: '', inboxId: '' });
const metaForm = reactive({
  name: '',
  inboxId: '',
  metaFormId: '',
  metaPageId: '',
  verifyToken: '',
});
const inboxes = useMapGetter('inboxes/getInboxes');

const accountId = computed(() => route.params.accountId);
const publicApiOrigin = window.location.origin;

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
const widgetForms = computed(() =>
  forms.value.filter(form => form.source_kind === 'widget')
);

const tabs = computed(() => [
  {
    id: 'meta',
    label: t('LEAD_FORMS.TABS.META'),
    count: metaForms.value.length,
  },
  { id: 'api', label: t('LEAD_FORMS.TABS.API'), count: apiForms.value.length },
  {
    id: 'widget',
    label: t('LEAD_FORMS.TABS.WIDGET_CHAT'),
    count: widgetForms.value.length,
  },
]);

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

const widgetInboxOptions = computed(() =>
  inboxes.value
    .filter(inbox => inbox.channel_type === INBOX_TYPES.WEB)
    .sort((a, b) => a.name.localeCompare(b.name))
    .map(inboxOption)
);

const widgetInboxes = computed(() =>
  inboxes.value
    .filter(inbox => inbox.channel_type === INBOX_TYPES.WEB)
    .sort((a, b) => a.name.localeCompare(b.name))
);

const selectedWidgetInbox = computed(() =>
  widgetInboxes.value.find(
    inbox => String(inbox.id) === String(selectedWidgetInboxId.value)
  )
);

const selectedMetaConnection = computed(() =>
  inboxes.value.find(
    inbox => String(inbox.id) === String(selectedMetaConnectionId.value)
  )
);

const apiSubmissions = computed(() =>
  submissions.value.filter(submission => submission.source_kind === 'api')
);
const metaSubmissions = computed(() =>
  submissions.value.filter(submission => submission.source_kind === 'meta')
);
const widgetSubmissions = computed(() =>
  submissions.value.filter(submission => submission.source_kind === 'widget')
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
  isLoading.value = true;
  try {
    const [formsResponse, submissionsResponse] = await Promise.all([
      leadFormsAPI.get(),
      leadSubmissionsAPI.get({ limit: 20 }),
    ]);
    forms.value = formsResponse.data.payload || [];
    submissions.value = submissionsResponse.data.payload || [];
  } catch (error) {
    useAlert(t('LEAD_FORMS.ERRORS.LOAD'));
  } finally {
    isLoading.value = false;
  }
};

const loadPage = async () => {
  isLoading.value = true;
  try {
    await Promise.all([
      store.dispatch('inboxes/get'),
      store.dispatch('attributes/get'),
      fetchLeadIntake(),
    ]);
  } catch (error) {
    useAlert(t('LEAD_FORMS.ERRORS.LOAD'));
  } finally {
    isLoading.value = false;
  }
};

const enabledApiFields = () =>
  apiFormFields.value
    .filter(field => field.enabled)
    .map(field => ({
      name: field.name?.trim(),
      label: field.label?.trim(),
      placeholder: field.placeholder?.trim(),
      type: field.type || 'text',
      required: field.required === true,
    }))
    .filter(field => field.name && field.label);

const createApiForm = async () => {
  const fieldSchema = enabledApiFields();

  if (!apiForm.name || !apiForm.inboxId || !fieldSchema.length) {
    useAlert(t('LEAD_FORMS.ERRORS.REQUIRED'));
    return;
  }

  savingSource.value = 'api';
  try {
    await leadFormsAPI.create({
      name: apiForm.name,
      inbox_id: Number(apiForm.inboxId),
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
      source_kind: 'meta',
      status: 'active',
      external_ref: metaForm.metaFormId,
      field_schema: [],
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

const submissionTitle = submission =>
  submission.contact_name ||
  submission.field_values?.full_name ||
  submission.field_values?.fullName ||
  `#${submission.id}`;

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
  widgetInboxOptions,
  options => {
    if (!selectedWidgetInboxId.value && options[0]) {
      selectedWidgetInboxId.value = options[0].value;
    }
  },
  { immediate: true }
);

onMounted(loadPage);
</script>

<template>
  <main
    class="flex h-full min-h-0 flex-col overflow-y-auto bg-n-background p-6"
  >
    <section class="w-full max-w-6xl mx-auto space-y-6">
      <header
        class="rounded-3xl border border-n-weak bg-gradient-to-br from-n-solid-1 to-n-alpha-2 p-5"
      >
        <p class="text-sm font-medium text-n-blue-text">
          {{ $t('LEAD_FORMS.KICKER') }}
        </p>
        <div
          class="mt-1 flex flex-col gap-3 lg:flex-row lg:items-end lg:justify-between"
        >
          <div>
            <h1 class="text-2xl font-semibold text-n-slate-12">
              {{ $t('LEAD_FORMS.TITLE') }}
            </h1>
            <p class="mt-2 max-w-3xl text-sm text-n-slate-11">
              {{ $t('LEAD_FORMS.DESCRIPTION') }}
            </p>
          </div>
          <Button
            :label="$t('LEAD_FORMS.REFRESH')"
            variant="secondary"
            size="sm"
            :is-loading="isLoading"
            @click="loadPage"
          />
        </div>
        <div
          class="mt-5 inline-flex flex-wrap rounded-2xl border border-n-weak bg-n-background p-1"
        >
          <button
            v-for="tab in tabs"
            :key="tab.id"
            type="button"
            class="rounded-xl px-4 py-2 text-sm font-medium transition"
            :class="
              activeTab === tab.id
                ? 'bg-n-brand text-white shadow-sm'
                : 'text-n-slate-11 hover:bg-n-alpha-2 hover:text-n-slate-12'
            "
            @click="activeTab = tab.id"
          >
            {{ tab.label }}
            <span class="opacity-70">{{ tab.count }}</span>
          </button>
        </div>
      </header>

      <section v-if="activeTab === 'meta'" class="grid gap-4 lg:grid-cols-2">
        <article class="rounded-3xl border border-n-weak bg-n-solid-1 p-5">
          <div class="mb-5 flex items-start gap-3">
            <div
              class="flex size-11 shrink-0 items-center justify-center rounded-2xl bg-n-brand/10 text-n-brand"
            >
              <span class="i-ri-meta-fill text-2xl" />
            </div>
            <div>
              <h2 class="text-lg font-semibold text-n-slate-12">
                {{ $t('LEAD_FORMS.META_FORMS.NEW_TITLE') }}
              </h2>
              <p class="text-sm text-n-slate-11">
                {{ $t('LEAD_FORMS.META_FORMS.NEW_DESCRIPTION') }}
              </p>
            </div>
          </div>

          <div
            v-if="!metaConnectionOptions.length"
            class="mb-5 rounded-2xl border border-n-amber-6 bg-n-amber-3 p-4"
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
            <label class="block space-y-1">
              <span class="text-sm font-medium text-n-slate-12">
                {{ $t('LEAD_FORMS.META_FORMS.NAME_LABEL') }}
              </span>
              <input
                v-model="metaForm.name"
                class="h-10 w-full rounded-xl border border-n-weak bg-n-background px-3 text-sm text-n-slate-12"
                :placeholder="$t('LEAD_FORMS.META_FORMS.NAME_PLACEHOLDER')"
              />
            </label>
            <div class="grid gap-3 md:grid-cols-2">
              <label class="space-y-1">
                <span class="text-sm font-medium text-n-slate-12">
                  {{ $t('LEAD_FORMS.META_FORMS.FORM_ID_LABEL') }}
                </span>
                <input
                  v-model="metaForm.metaFormId"
                  class="h-10 w-full rounded-xl border border-n-weak bg-n-background px-3 text-sm text-n-slate-12"
                  :placeholder="$t('LEAD_FORMS.META_FORMS.FORM_ID_PLACEHOLDER')"
                />
              </label>
              <label class="space-y-1">
                <span class="text-sm font-medium text-n-slate-12">
                  {{ $t('LEAD_FORMS.META_FORMS.PAGE_ID_LABEL') }}
                </span>
                <input
                  v-model="metaForm.metaPageId"
                  class="h-10 w-full rounded-xl border border-n-weak bg-n-background px-3 text-sm text-n-slate-12"
                  :placeholder="$t('LEAD_FORMS.META_FORMS.PAGE_ID_PLACEHOLDER')"
                />
              </label>
            </div>
            <label class="block space-y-1">
              <span class="text-sm font-medium text-n-slate-12">
                {{ $t('LEAD_FORMS.META_FORMS.VERIFY_TOKEN_LABEL') }}
              </span>
              <input
                v-model="metaForm.verifyToken"
                class="h-10 w-full rounded-xl border border-n-weak bg-n-background px-3 text-sm text-n-slate-12"
                :placeholder="
                  $t('LEAD_FORMS.META_FORMS.VERIFY_TOKEN_PLACEHOLDER')
                "
              />
            </label>
            <p class="text-sm text-n-slate-11">
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

        <article class="rounded-3xl border border-n-weak bg-n-solid-1 p-5">
          <h2 class="text-lg font-semibold text-n-slate-12">
            {{ $t('LEAD_FORMS.META_FORMS.LIST_TITLE') }}
          </h2>
          <div class="mt-3 divide-y divide-n-weak">
            <p v-if="!metaForms.length" class="py-4 text-sm text-n-slate-11">
              {{ $t('LEAD_FORMS.META_FORMS.EMPTY') }}
            </p>
            <div v-for="form in metaForms" :key="form.id" class="py-3">
              <p class="font-medium text-n-slate-12">{{ form.name }}</p>
              <p class="text-xs text-n-slate-11">
                {{ form.external_ref || form.settings?.meta_form_id }}
                {{ $t('LEAD_FORMS.SEPARATOR') }}
                {{ form.inbox_name || `Inbox #${form.inbox_id}` }}
                {{ $t('LEAD_FORMS.SEPARATOR') }}
                {{ statusLabel(form.status) }}
              </p>
            </div>
          </div>
        </article>

        <article
          class="rounded-3xl border border-n-weak bg-n-solid-1 p-5 lg:col-span-2"
        >
          <h2 class="text-lg font-semibold text-n-slate-12">
            {{ $t('LEAD_FORMS.SUBMISSIONS.TITLE') }}
          </h2>
          <div class="mt-3 divide-y divide-n-weak">
            <p
              v-if="!metaSubmissions.length"
              class="py-4 text-sm text-n-slate-11"
            >
              {{ $t('LEAD_FORMS.SUBMISSIONS.EMPTY') }}
            </p>
            <div
              v-for="submission in metaSubmissions"
              :key="submission.id"
              class="py-3"
            >
              <div class="flex items-start justify-between gap-4">
                <div>
                  <p class="font-medium text-n-slate-12">
                    {{ submissionTitle(submission) }}
                  </p>
                  <p class="text-xs text-n-slate-11">
                    {{ submission.lead_form_name }}
                    {{ $t('LEAD_FORMS.SEPARATOR') }}
                    {{ statusLabel(submission.status) }}
                  </p>
                </div>
                <router-link
                  v-if="submission.conversation_id"
                  class="text-sm text-n-blue-text hover:underline"
                  :to="{
                    name: 'inbox_conversation',
                    params: {
                      accountId,
                      conversation_id: submission.conversation_id,
                    },
                  }"
                >
                  {{ $t('LEAD_FORMS.SUBMISSIONS.OPEN_CONVERSATION') }}
                </router-link>
              </div>
            </div>
          </div>
        </article>
      </section>

      <section v-if="activeTab === 'api'" class="grid gap-4 lg:grid-cols-2">
        <article
          class="rounded-3xl border border-n-weak bg-n-solid-1 p-5 lg:col-span-2"
        >
          <div class="mb-5 flex items-start gap-3">
            <div
              class="flex size-11 shrink-0 items-center justify-center rounded-2xl bg-n-brand/10 text-n-brand"
            >
              <span class="i-lucide-form-input text-2xl" />
            </div>
            <div>
              <h2 class="text-lg font-semibold text-n-slate-12">
                {{ $t('LEAD_FORMS.API_FORMS.NEW_TITLE') }}
              </h2>
              <p class="text-sm text-n-slate-11">
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
                <input
                  v-model="apiForm.name"
                  class="h-10 w-full rounded-xl border border-n-weak bg-n-background px-3 text-sm text-n-slate-12"
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

            <p
              v-if="!leadTargetInboxOptions.length"
              class="rounded-2xl border border-n-amber-6 bg-n-amber-3 p-3 text-sm text-n-amber-11"
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

        <article class="rounded-3xl border border-n-weak bg-n-solid-1 p-5">
          <h2 class="text-lg font-semibold text-n-slate-12">
            {{ $t('LEAD_FORMS.API_FORMS.LIST_TITLE') }}
          </h2>
          <div class="mt-3 divide-y divide-n-weak">
            <p v-if="!apiForms.length" class="py-4 text-sm text-n-slate-11">
              {{ $t('LEAD_FORMS.EMPTY') }}
            </p>
            <div v-for="form in apiForms" :key="form.id" class="py-4 space-y-3">
              <div class="flex items-start justify-between gap-4">
                <div>
                  <p class="font-medium text-n-slate-12">{{ form.name }}</p>
                  <p class="text-xs text-n-slate-11">
                    {{ form.inbox_name || `Inbox #${form.inbox_id}` }}
                    {{ $t('LEAD_FORMS.SEPARATOR') }}
                    {{ statusLabel(form.status) }}
                  </p>
                </div>
              </div>
              <div class="space-y-2 rounded-2xl bg-n-background p-3">
                <p class="text-xs font-medium uppercase text-n-slate-10">
                  {{ $t('LEAD_FORMS.API_FORMS.ENDPOINT_TITLE') }}
                </p>
                <code
                  class="block break-all rounded bg-n-alpha-2 px-2 py-1 text-xs"
                >
                  {{ postEndpointFor(form) }}
                </code>
                <p class="text-xs font-medium uppercase text-n-slate-10">
                  {{ $t('LEAD_FORMS.API_FORMS.TOKEN_LABEL') }}
                </p>
                <code
                  class="block break-all rounded bg-n-alpha-2 px-2 py-1 text-xs"
                >
                  {{ form.public_token }}
                </code>
                <p class="text-xs font-medium uppercase text-n-slate-10">
                  {{ $t('LEAD_FORMS.API_FORMS.JSON_EXAMPLE') }}
                </p>
                <pre
                  class="max-h-72 overflow-auto rounded bg-n-alpha-2 p-3 text-xs text-n-slate-12"
                ><code>{{ sampleJsonFor(form) }}</code></pre>
              </div>
            </div>
          </div>
        </article>

        <article class="rounded-3xl border border-n-weak bg-n-solid-1 p-5">
          <h2 class="text-lg font-semibold text-n-slate-12">
            {{ $t('LEAD_FORMS.SUBMISSIONS.TITLE') }}
          </h2>
          <div class="mt-3 divide-y divide-n-weak">
            <p
              v-if="!apiSubmissions.length"
              class="py-4 text-sm text-n-slate-11"
            >
              {{ $t('LEAD_FORMS.SUBMISSIONS.EMPTY') }}
            </p>
            <div
              v-for="submission in apiSubmissions"
              :key="submission.id"
              class="py-3"
            >
              <div class="flex items-start justify-between gap-4">
                <div>
                  <p class="font-medium text-n-slate-12">
                    {{ submissionTitle(submission) }}
                  </p>
                  <p class="text-xs text-n-slate-11">
                    {{ submission.lead_form_name }}
                    {{ $t('LEAD_FORMS.SEPARATOR') }}
                    {{ statusLabel(submission.status) }}
                  </p>
                </div>
                <router-link
                  v-if="submission.conversation_id"
                  class="text-sm text-n-blue-text hover:underline"
                  :to="{
                    name: 'inbox_conversation',
                    params: {
                      accountId,
                      conversation_id: submission.conversation_id,
                    },
                  }"
                >
                  {{ $t('LEAD_FORMS.SUBMISSIONS.OPEN_CONVERSATION') }}
                </router-link>
              </div>
            </div>
          </div>
        </article>
      </section>

      <section v-if="activeTab === 'widget'" class="space-y-4">
        <section class="rounded-3xl border border-n-weak bg-n-solid-1 p-5">
          <div
            class="mb-4 flex flex-col gap-3 lg:flex-row lg:items-start lg:justify-between"
          >
            <div>
              <h2 class="text-lg font-semibold text-n-slate-12">
                {{ $t('LEAD_FORMS.WIDGET_FORMS.NEW_TITLE') }}
              </h2>
              <p class="text-sm text-n-slate-11">
                {{ $t('LEAD_FORMS.WIDGET_FORMS.NEW_DESCRIPTION') }}
              </p>
            </div>
            <ComboBox
              v-if="widgetInboxOptions.length"
              v-model="selectedWidgetInboxId"
              class="w-full lg:w-80"
              :options="widgetInboxOptions"
              :placeholder="$t('LEAD_FORMS.WIDGET_FORMS.SELECT_INBOX')"
              input-like
            />
          </div>

          <div
            v-if="selectedWidgetInbox"
            class="rounded-2xl border border-n-weak bg-n-background py-4"
          >
            <div class="mb-4 flex items-center gap-3 px-6">
              <span
                class="flex size-10 items-center justify-center rounded-xl bg-n-brand/10 text-n-brand"
                :class="getInboxIconByType(selectedWidgetInbox.channel_type)"
              />
              <div>
                <p class="font-medium text-n-slate-12">
                  {{ selectedWidgetInbox.name }}
                </p>
                <p class="text-xs text-n-slate-11">
                  {{
                    selectedWidgetInbox.website_url ||
                    selectedWidgetInbox.channel_type
                  }}
                </p>
              </div>
            </div>
            <PreChatFormSettings
              :inbox="selectedWidgetInbox"
              @saved="fetchLeadIntake"
            />
          </div>
          <p v-else class="py-4 text-sm text-n-slate-11">
            {{ $t('LEAD_FORMS.WIDGET_FORMS.EMPTY') }}
          </p>
        </section>

        <section class="rounded-3xl border border-n-weak bg-n-solid-1 p-5">
          <h2 class="text-lg font-semibold text-n-slate-12">
            {{ $t('LEAD_FORMS.WIDGET_FORMS.LIST_TITLE') }}
          </h2>
          <div class="mt-3 divide-y divide-n-weak">
            <p v-if="!widgetForms.length" class="py-4 text-sm text-n-slate-11">
              {{ $t('LEAD_FORMS.WIDGET_FORMS.EMPTY') }}
            </p>
            <div v-for="form in widgetForms" :key="form.id" class="py-3">
              <p class="font-medium text-n-slate-12">{{ form.name }}</p>
              <p class="text-xs text-n-slate-11">
                {{ form.inbox_name || `Inbox #${form.inbox_id}` }}
                {{ $t('LEAD_FORMS.SEPARATOR') }}
                {{ statusLabel(form.status) }}
              </p>
            </div>
          </div>
        </section>

        <section class="rounded-3xl border border-n-weak bg-n-solid-1 p-5">
          <h2 class="text-lg font-semibold text-n-slate-12">
            {{ $t('LEAD_FORMS.SUBMISSIONS.TITLE') }}
          </h2>
          <div class="mt-3 divide-y divide-n-weak">
            <p
              v-if="!widgetSubmissions.length"
              class="py-4 text-sm text-n-slate-11"
            >
              {{ $t('LEAD_FORMS.SUBMISSIONS.EMPTY') }}
            </p>
            <div
              v-for="submission in widgetSubmissions"
              :key="submission.id"
              class="py-3"
            >
              <div class="flex items-start justify-between gap-4">
                <div>
                  <p class="font-medium text-n-slate-12">
                    {{ submissionTitle(submission) }}
                  </p>
                  <p class="text-xs text-n-slate-11">
                    {{ submission.lead_form_name }}
                    {{ $t('LEAD_FORMS.SEPARATOR') }}
                    {{ statusLabel(submission.status) }}
                  </p>
                </div>
                <router-link
                  v-if="submission.conversation_id"
                  class="text-sm text-n-blue-text hover:underline"
                  :to="{
                    name: 'inbox_conversation',
                    params: {
                      accountId,
                      conversation_id: submission.conversation_id,
                    },
                  }"
                >
                  {{ $t('LEAD_FORMS.SUBMISSIONS.OPEN_CONVERSATION') }}
                </router-link>
              </div>
            </div>
          </div>
        </section>
      </section>
    </section>
  </main>
</template>
