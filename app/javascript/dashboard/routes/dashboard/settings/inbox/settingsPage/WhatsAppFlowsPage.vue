<script setup>
import { computed, onMounted, reactive, ref, watch } from 'vue';
import { useI18n } from 'vue-i18n';
import { useAlert } from 'dashboard/composables';
import { useStore } from 'dashboard/composables/store';

import Button from 'dashboard/components-next/button/Button.vue';
import Dialog from 'dashboard/components-next/dialog/Dialog.vue';
import Input from 'dashboard/components-next/input/Input.vue';
import Select from 'dashboard/components-next/select/Select.vue';
import SettingsFieldSection from 'dashboard/components-next/Settings/SettingsFieldSection.vue';
import TextArea from 'dashboard/components-next/textarea/TextArea.vue';

const props = defineProps({
  inbox: {
    type: Object,
    required: true,
  },
});

const { t } = useI18n();
const store = useStore();

const searchQuery = ref('');
const isFetchingFlows = ref(false);
const isSubmittingFlow = ref(false);
const isDeletingFlow = ref(false);
const selectedFlow = ref(null);
const flowPendingDelete = ref(null);
const formDialogRef = ref(null);
const deleteDialogRef = ref(null);

const form = reactive({
  providerFlowId: '',
  name: '',
  title: '',
  status: 'published',
  category: '',
  mode: 'published',
  cta: '',
  flowJsonText: '{}',
});

const statusOptions = computed(() => [
  { value: 'draft', label: t('WHATSAPP_FLOWS.SETTINGS.STATUS_OPTIONS.DRAFT') },
  {
    value: 'published',
    label: t('WHATSAPP_FLOWS.SETTINGS.STATUS_OPTIONS.PUBLISHED'),
  },
  {
    value: 'deprecated',
    label: t('WHATSAPP_FLOWS.SETTINGS.STATUS_OPTIONS.DEPRECATED'),
  },
  {
    value: 'blocked',
    label: t('WHATSAPP_FLOWS.SETTINGS.STATUS_OPTIONS.BLOCKED'),
  },
  {
    value: 'unknown',
    label: t('WHATSAPP_FLOWS.SETTINGS.STATUS_OPTIONS.UNKNOWN'),
  },
]);

const modeOptions = computed(() => [
  { value: '', label: t('WHATSAPP_FLOWS.SETTINGS.MODE_OPTIONS.BLANK') },
  { value: 'draft', label: t('WHATSAPP_FLOWS.SETTINGS.MODE_OPTIONS.DRAFT') },
  {
    value: 'published',
    label: t('WHATSAPP_FLOWS.SETTINGS.MODE_OPTIONS.PUBLISHED'),
  },
]);

const whatsAppFlows = computed(() =>
  store.getters['inboxes/getWhatsAppFlows'](props.inbox.id)
);

const filteredFlows = computed(() => {
  const query = searchQuery.value.trim().toLowerCase();
  if (!query) return whatsAppFlows.value;

  return whatsAppFlows.value.filter(flow =>
    [
      flow.name,
      flow.title,
      flow.display_title,
      flow.provider_flow_id,
      flow.status,
      flow.category,
      flow.mode,
    ]
      .filter(Boolean)
      .some(value => String(value).toLowerCase().includes(query))
  );
});

const formTitle = computed(() =>
  selectedFlow.value
    ? t('WHATSAPP_FLOWS.SETTINGS.EDIT_TITLE')
    : t('WHATSAPP_FLOWS.SETTINGS.CREATE_TITLE')
);

const formDescription = computed(() =>
  selectedFlow.value
    ? t('WHATSAPP_FLOWS.SETTINGS.EDIT_DESCRIPTION')
    : t('WHATSAPP_FLOWS.SETTINGS.CREATE_DESCRIPTION')
);

const getFlowTitle = flow => flow.display_title || flow.title || flow.name;
const getFlowCta = flow =>
  flow?.metadata?.flow_cta || flow?.metadata?.cta || '';

const formatDate = value => {
  if (!value) return t('WHATSAPP_FLOWS.SETTINGS.NEVER_SYNCED');

  return new Intl.DateTimeFormat(undefined, {
    dateStyle: 'medium',
    timeStyle: 'short',
  }).format(new Date(value));
};

const getStatusClass = status => {
  const statusKey = String(status || '').toLowerCase();
  const classes = {
    published: 'bg-n-teal-9/10 text-n-teal-11',
    draft: 'bg-n-amber-9/10 text-n-amber-11',
    deprecated: 'bg-n-slate-4 text-n-slate-11',
    blocked: 'bg-n-ruby-9/10 text-n-ruby-11',
    unknown: 'bg-n-slate-4 text-n-slate-11',
  };

  return classes[statusKey] || classes.unknown;
};

const normalizeJsonText = value => {
  if (!value || !String(value).trim()) return '{}';

  try {
    const parsed = JSON.parse(value);
    return JSON.stringify(parsed, null, 2);
  } catch {
    return value;
  }
};

const resetForm = (flow = null) => {
  selectedFlow.value = flow;
  form.providerFlowId = flow?.provider_flow_id || '';
  form.name = flow?.name || '';
  form.title = flow?.title || '';
  form.status = flow?.status || 'published';
  form.category = flow?.category || '';
  form.mode = flow?.mode || 'published';
  form.cta = getFlowCta(flow);
  form.flowJsonText = JSON.stringify(flow?.flow_json || {}, null, 2);
};

const fetchFlows = async () => {
  if (!props.inbox?.id) return;

  isFetchingFlows.value = true;
  try {
    await store.dispatch('inboxes/fetchWhatsAppFlows', props.inbox.id);
  } catch (error) {
    useAlert(error.message || t('WHATSAPP_FLOWS.SETTINGS.LOAD_ERROR'));
  } finally {
    isFetchingFlows.value = false;
  }
};

const openCreateDialog = () => {
  resetForm();
  formDialogRef.value?.open();
};

const openEditDialog = flow => {
  resetForm(flow);
  formDialogRef.value?.open();
};

const openDeleteDialog = flow => {
  flowPendingDelete.value = flow;
  deleteDialogRef.value?.open();
};

const closeFormDialog = () => {
  formDialogRef.value?.close();
};

const parseFlowJson = () => {
  const parsed = JSON.parse(form.flowJsonText || '{}');
  if (!parsed || Array.isArray(parsed) || typeof parsed !== 'object') {
    throw new Error(t('WHATSAPP_FLOWS.SETTINGS.ERRORS.FLOW_JSON_OBJECT'));
  }

  return parsed;
};

const buildFlowPayload = () => {
  if (!form.name.trim()) {
    throw new Error(t('WHATSAPP_FLOWS.SETTINGS.ERRORS.NAME_REQUIRED'));
  }
  if (!form.status) {
    throw new Error(t('WHATSAPP_FLOWS.SETTINGS.ERRORS.STATUS_REQUIRED'));
  }

  const existingMetadata = selectedFlow.value?.metadata || {};
  const metadata = { ...existingMetadata };
  if (form.cta.trim()) {
    metadata.flow_cta = form.cta.trim();
  } else {
    delete metadata.flow_cta;
  }

  return {
    provider_flow_id: form.providerFlowId.trim() || null,
    name: form.name.trim(),
    title: form.title.trim() || null,
    status: form.status,
    category: form.category.trim() || null,
    mode: form.mode || null,
    flow_json: parseFlowJson(),
    metadata,
  };
};

const saveFlow = async () => {
  let flowPayload;
  try {
    flowPayload = buildFlowPayload();
  } catch (error) {
    useAlert(error.message);
    return;
  }

  isSubmittingFlow.value = true;
  try {
    if (selectedFlow.value) {
      await store.dispatch('inboxes/updateWhatsAppFlow', {
        inboxId: props.inbox.id,
        flowId: selectedFlow.value.id,
        flow: flowPayload,
      });
      useAlert(t('WHATSAPP_FLOWS.SETTINGS.UPDATE_SUCCESS'));
    } else {
      await store.dispatch('inboxes/createWhatsAppFlow', {
        inboxId: props.inbox.id,
        flow: flowPayload,
      });
      useAlert(t('WHATSAPP_FLOWS.SETTINGS.CREATE_SUCCESS'));
    }

    closeFormDialog();
  } catch (error) {
    useAlert(error.message || t('WHATSAPP_FLOWS.SETTINGS.SAVE_ERROR'));
  } finally {
    isSubmittingFlow.value = false;
  }
};

const deleteFlow = async () => {
  if (!flowPendingDelete.value) return;

  isDeletingFlow.value = true;
  try {
    await store.dispatch('inboxes/deleteWhatsAppFlow', {
      inboxId: props.inbox.id,
      flowId: flowPendingDelete.value.id,
    });
    useAlert(t('WHATSAPP_FLOWS.SETTINGS.DELETE_SUCCESS'));
    deleteDialogRef.value?.close();
    flowPendingDelete.value = null;
  } catch (error) {
    useAlert(error.message || t('WHATSAPP_FLOWS.SETTINGS.DELETE_ERROR'));
  } finally {
    isDeletingFlow.value = false;
  }
};

watch(
  () => props.inbox.id,
  () => fetchFlows()
);

onMounted(fetchFlows);
</script>

<template>
  <div class="mx-6 max-w-7xl space-y-6">
    <SettingsFieldSection
      :label="t('WHATSAPP_FLOWS.SETTINGS.PAGE_TITLE')"
      :help-text="t('WHATSAPP_FLOWS.SETTINGS.PAGE_DESCRIPTION')"
    >
      <div class="space-y-5">
        <div
          class="flex flex-col gap-3 rounded-2xl border border-n-weak bg-n-surface-1 p-4 md:flex-row md:items-center md:justify-between"
        >
          <div class="space-y-1">
            <p class="mb-0 text-sm font-medium text-n-slate-12">
              {{ t('WHATSAPP_FLOWS.SETTINGS.SUPPORTED_TITLE') }}
            </p>
            <p class="mb-0 text-sm text-n-slate-11">
              {{ t('WHATSAPP_FLOWS.SETTINGS.SUPPORTED_DESCRIPTION') }}
            </p>
          </div>
          <div class="flex flex-wrap items-center gap-3">
            <Button
              variant="outline"
              color="slate"
              icon="i-lucide-refresh-cw"
              :label="t('WHATSAPP_FLOWS.SETTINGS.REFRESH')"
              :is-loading="isFetchingFlows"
              @click="fetchFlows"
            />
            <Button
              icon="i-lucide-plus"
              :label="t('WHATSAPP_FLOWS.SETTINGS.CREATE_ACTION')"
              @click="openCreateDialog"
            />
          </div>
        </div>

        <Input
          v-model="searchQuery"
          type="search"
          :placeholder="t('WHATSAPP_FLOWS.SETTINGS.SEARCH_PLACEHOLDER')"
        />

        <div
          v-if="isFetchingFlows && !whatsAppFlows.length"
          class="rounded-2xl border border-n-weak bg-n-surface-1 p-8 text-center text-sm text-n-slate-11"
        >
          {{ t('WHATSAPP_FLOWS.SETTINGS.LOADING') }}
        </div>

        <div
          v-else-if="!whatsAppFlows.length"
          class="rounded-2xl border border-dashed border-n-weak bg-n-surface-1 p-8 text-center"
        >
          <p class="mb-1 text-base font-medium text-n-slate-12">
            {{ t('WHATSAPP_FLOWS.SETTINGS.EMPTY_TITLE') }}
          </p>
          <p class="mb-0 text-sm text-n-slate-11">
            {{ t('WHATSAPP_FLOWS.SETTINGS.EMPTY_DESCRIPTION') }}
          </p>
        </div>

        <div
          v-else-if="!filteredFlows.length"
          class="rounded-2xl border border-dashed border-n-weak bg-n-surface-1 p-8 text-center"
        >
          <p class="mb-1 text-base font-medium text-n-slate-12">
            {{ t('WHATSAPP_FLOWS.SETTINGS.NO_RESULTS_TITLE') }}
          </p>
          <p class="mb-0 text-sm text-n-slate-11">
            {{ t('WHATSAPP_FLOWS.SETTINGS.NO_RESULTS_DESCRIPTION') }}
          </p>
        </div>

        <div v-else class="grid grid-cols-1 gap-4 xl:grid-cols-2">
          <div
            v-for="flow in filteredFlows"
            :key="flow.id"
            class="space-y-4 rounded-2xl border border-n-weak bg-n-surface-1 p-4"
          >
            <div class="flex items-start justify-between gap-4">
              <div class="min-w-0 space-y-2">
                <div class="flex flex-wrap items-center gap-2">
                  <p
                    class="mb-0 truncate text-base font-medium text-n-slate-12"
                  >
                    {{ getFlowTitle(flow) }}
                  </p>
                  <span
                    class="rounded-full px-2.5 py-1 text-xs font-medium"
                    :class="getStatusClass(flow.status)"
                  >
                    {{ flow.status || 'unknown' }}
                  </span>
                  <span
                    v-if="flow.mode"
                    class="rounded-full bg-n-alpha-black2 px-2.5 py-1 text-xs font-medium text-n-slate-11"
                  >
                    {{ flow.mode }}
                  </span>
                </div>
                <p class="mb-0 truncate text-xs text-n-slate-10">
                  {{
                    flow.provider_flow_id ||
                    t('WHATSAPP_FLOWS.SETTINGS.NO_PROVIDER_ID')
                  }}
                </p>
              </div>
              <div class="flex flex-shrink-0 items-center gap-2">
                <Button
                  variant="ghost"
                  color="slate"
                  size="sm"
                  icon="i-lucide-pencil"
                  :label="t('WHATSAPP_FLOWS.SETTINGS.EDIT_ACTION')"
                  @click="openEditDialog(flow)"
                />
                <Button
                  variant="ghost"
                  color="ruby"
                  size="sm"
                  icon="i-lucide-trash-2"
                  :label="t('WHATSAPP_FLOWS.SETTINGS.DELETE_ACTION')"
                  @click="openDeleteDialog(flow)"
                />
              </div>
            </div>

            <div class="grid gap-3 text-sm md:grid-cols-2">
              <div class="rounded-xl bg-n-alpha-black2 p-3">
                <p class="mb-1 text-xs uppercase tracking-wide text-n-slate-10">
                  {{ t('WHATSAPP_FLOWS.SETTINGS.CARD.NAME') }}
                </p>
                <p class="mb-0 break-words text-n-slate-12">{{ flow.name }}</p>
              </div>
              <div class="rounded-xl bg-n-alpha-black2 p-3">
                <p class="mb-1 text-xs uppercase tracking-wide text-n-slate-10">
                  {{ t('WHATSAPP_FLOWS.SETTINGS.CARD.CATEGORY') }}
                </p>
                <p class="mb-0 break-words text-n-slate-12">
                  {{ flow.category || '—' }}
                </p>
              </div>
              <div class="rounded-xl bg-n-alpha-black2 p-3">
                <p class="mb-1 text-xs uppercase tracking-wide text-n-slate-10">
                  {{ t('WHATSAPP_FLOWS.SETTINGS.CARD.CTA') }}
                </p>
                <p class="mb-0 break-words text-n-slate-12">
                  {{ getFlowCta(flow) || '—' }}
                </p>
              </div>
              <div class="rounded-xl bg-n-alpha-black2 p-3">
                <p class="mb-1 text-xs uppercase tracking-wide text-n-slate-10">
                  {{ t('WHATSAPP_FLOWS.SETTINGS.CARD.UPDATED') }}
                </p>
                <p class="mb-0 break-words text-n-slate-12">
                  {{ formatDate(flow.updated_at) }}
                </p>
              </div>
            </div>
          </div>
        </div>
      </div>
    </SettingsFieldSection>

    <Dialog
      ref="formDialogRef"
      width="3xl"
      overflow-y-auto
      :title="formTitle"
      :description="formDescription"
      :confirm-button-label="t('WHATSAPP_FLOWS.SETTINGS.SAVE_ACTION')"
      :is-loading="isSubmittingFlow"
      @confirm="saveFlow"
      @close="resetForm()"
    >
      <div class="grid gap-4 md:grid-cols-2">
        <Input
          v-model="form.providerFlowId"
          :label="t('WHATSAPP_FLOWS.SETTINGS.FIELDS.PROVIDER_FLOW_ID')"
          :placeholder="
            t('WHATSAPP_FLOWS.SETTINGS.FIELDS.PROVIDER_FLOW_ID_PLACEHOLDER')
          "
        />
        <Input
          v-model="form.name"
          :label="t('WHATSAPP_FLOWS.SETTINGS.FIELDS.NAME')"
          :placeholder="t('WHATSAPP_FLOWS.SETTINGS.FIELDS.NAME_PLACEHOLDER')"
        />
        <Input
          v-model="form.title"
          :label="t('WHATSAPP_FLOWS.SETTINGS.FIELDS.TITLE')"
          :placeholder="t('WHATSAPP_FLOWS.SETTINGS.FIELDS.TITLE_PLACEHOLDER')"
        />
        <Input
          v-model="form.category"
          :label="t('WHATSAPP_FLOWS.SETTINGS.FIELDS.CATEGORY')"
          :placeholder="
            t('WHATSAPP_FLOWS.SETTINGS.FIELDS.CATEGORY_PLACEHOLDER')
          "
        />
        <label class="flex flex-col gap-1">
          <span class="text-heading-3 text-n-slate-12">
            {{ t('WHATSAPP_FLOWS.SETTINGS.FIELDS.STATUS') }}
          </span>
          <Select
            v-model="form.status"
            class="w-full"
            :options="statusOptions"
          />
        </label>
        <label class="flex flex-col gap-1">
          <span class="text-heading-3 text-n-slate-12">
            {{ t('WHATSAPP_FLOWS.SETTINGS.FIELDS.MODE') }}
          </span>
          <Select v-model="form.mode" class="w-full" :options="modeOptions" />
        </label>
        <Input
          v-model="form.cta"
          class="md:col-span-2"
          :label="t('WHATSAPP_FLOWS.SETTINGS.FIELDS.CTA')"
          :placeholder="t('WHATSAPP_FLOWS.SETTINGS.FIELDS.CTA_PLACEHOLDER')"
        />
        <TextArea
          v-model="form.flowJsonText"
          class="md:col-span-2"
          :label="t('WHATSAPP_FLOWS.SETTINGS.FIELDS.FLOW_JSON')"
          :placeholder="
            t('WHATSAPP_FLOWS.SETTINGS.FIELDS.FLOW_JSON_PLACEHOLDER')
          "
          :max-length="20000"
          show-character-count
          resize
          min-height="12rem"
          @blur="form.flowJsonText = normalizeJsonText(form.flowJsonText)"
        />
      </div>
    </Dialog>

    <Dialog
      ref="deleteDialogRef"
      type="alert"
      :title="t('WHATSAPP_FLOWS.SETTINGS.DELETE_DIALOG.TITLE')"
      :description="
        t('WHATSAPP_FLOWS.SETTINGS.DELETE_DIALOG.DESCRIPTION', {
          flow: getFlowTitle(flowPendingDelete || {}),
        })
      "
      :confirm-button-label="t('WHATSAPP_FLOWS.SETTINGS.DELETE_DIALOG.CONFIRM')"
      :is-loading="isDeletingFlow"
      @confirm="deleteFlow"
      @close="flowPendingDelete = null"
    />
  </div>
</template>
