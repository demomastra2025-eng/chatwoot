<script setup>
import { computed, onMounted, reactive, ref } from 'vue';
import { useI18n } from 'vue-i18n';

import { useAlert } from 'dashboard/composables';
import { useMapGetter } from 'dashboard/composables/store';
import { usePolicy } from 'dashboard/composables/usePolicy';
import { FEATURE_FLAGS } from 'dashboard/featureFlags';
import Button from 'dashboard/components-next/button/Button.vue';
import Checkbox from 'dashboard/components-next/checkbox/Checkbox.vue';
import Input from 'dashboard/components-next/input/Input.vue';
import Spinner from 'dashboard/components-next/spinner/Spinner.vue';
import TextArea from 'dashboard/components-next/textarea/TextArea.vue';
import TagMultiSelectComboBox from 'dashboard/components-next/combobox/TagMultiSelectComboBox.vue';
import SchedulingDrawer from 'dashboard/components-next/Scheduling/SchedulingDrawer.vue';
import SchedulingErrorState from 'dashboard/components-next/Scheduling/SchedulingErrorState.vue';
import SchedulingFormFieldGroup from 'dashboard/components-next/Scheduling/SchedulingFormFieldGroup.vue';
import SchedulingRecordTable from 'dashboard/components-next/Scheduling/SchedulingRecordTable.vue';
import SchedulingSelectField from 'dashboard/components-next/Scheduling/SchedulingSelectField.vue';
import SchedulingViewSwitcher from 'dashboard/components-next/Scheduling/SchedulingViewSwitcher.vue';
import BaseSettingsHeader from '../components/BaseSettingsHeader.vue';
import SettingsLayout from '../SettingsLayout.vue';
import { useCrmReferencesStore } from 'dashboard/stores/crm/references';
import { formatCrmErrorMessage } from 'dashboard/stores/crm/shared';

const referencesStore = useCrmReferencesStore();
const { checkPermissions } = usePolicy();
const { t } = useI18n();

const pipelineDrawerOpen = ref(false);
const stageDrawerOpen = ref(false);
const taskStatusDrawerOpen = ref(false);
const fieldDrawerOpen = ref(false);
const fieldEntityKind = ref('deal');

const accountId = useMapGetter('getCurrentAccountId');
const isFeatureEnabledonAccount = useMapGetter(
  'accounts/isFeatureEnabledonAccount'
);

const dealsEnabled = computed(() =>
  isFeatureEnabledonAccount.value(accountId.value, FEATURE_FLAGS.CRM_DEALS)
);
const tasksEnabled = computed(() =>
  isFeatureEnabledonAccount.value(accountId.value, FEATURE_FLAGS.CRM_TASKS)
);
const canManage = computed(() =>
  checkPermissions(['administrator', 'crm_settings_manage'])
);

const pipelineForm = reactive({
  active: true,
  code: '',
  default: false,
  id: null,
  name: '',
  position: '',
});

const stageForm = reactive({
  active: true,
  code: '',
  id: null,
  name: '',
  outcome: 'open',
  pipelineId: '',
  position: '',
});

const taskStatusForm = reactive({
  active: true,
  category: 'open',
  code: '',
  default: false,
  id: null,
  name: '',
  position: '',
});

const fieldForm = reactive({
  active: true,
  contexts: [],
  defaultValue: '',
  description: '',
  entityKind: 'deal',
  fieldType: 'text',
  id: null,
  key: '',
  label: '',
  max: '',
  min: '',
  optionsText: '',
  position: '',
  regex: '',
  required: false,
});

const fieldTabs = computed(() => {
  return [
    dealsEnabled.value
      ? { label: t('CRM.SETTINGS.FIELD_TABS.DEALS'), value: 'deal' }
      : null,
    tasksEnabled.value
      ? { label: t('CRM.SETTINGS.FIELD_TABS.TASKS'), value: 'task' }
      : null,
  ].filter(Boolean);
});

const selectedFieldDefinitions = computed(() => {
  return fieldEntityKind.value === 'task'
    ? referencesStore.taskFieldDefinitions
    : referencesStore.dealFieldDefinitions;
});

const pipelineColumns = computed(() => [
  {
    key: 'name',
    label: t('CRM.SETTINGS.PIPELINES.TABLE.NAME'),
    width: '1.4fr',
  },
  {
    key: 'default',
    label: t('CRM.SETTINGS.PIPELINES.TABLE.DEFAULT'),
    width: '0.7fr',
  },
  {
    key: 'status',
    label: t('CRM.SETTINGS.PIPELINES.TABLE.STATUS'),
    width: '0.7fr',
  },
  {
    key: 'stages',
    label: t('CRM.SETTINGS.PIPELINES.TABLE.STAGES'),
    width: '1.8fr',
  },
  { key: 'actions', label: '', width: '124px', align: 'end' },
]);

const taskStatusColumns = computed(() => [
  {
    key: 'name',
    label: t('CRM.SETTINGS.TASK_STATUSES.TABLE.NAME'),
    width: '1.2fr',
  },
  {
    key: 'category',
    label: t('CRM.SETTINGS.TASK_STATUSES.TABLE.CATEGORY'),
    width: '0.8fr',
  },
  {
    key: 'default',
    label: t('CRM.SETTINGS.TASK_STATUSES.TABLE.DEFAULT'),
    width: '0.7fr',
  },
  {
    key: 'status',
    label: t('CRM.SETTINGS.TASK_STATUSES.TABLE.STATUS'),
    width: '0.7fr',
  },
  { key: 'actions', label: '', width: '72px', align: 'end' },
]);

const fieldColumns = computed(() => [
  { key: 'label', label: t('CRM.SETTINGS.FIELDS.TABLE.LABEL'), width: '1.2fr' },
  { key: 'key', label: t('CRM.SETTINGS.FIELDS.TABLE.KEY'), width: '1fr' },
  {
    key: 'fieldType',
    label: t('CRM.SETTINGS.FIELDS.TABLE.TYPE'),
    width: '0.8fr',
  },
  {
    key: 'context',
    label: t('CRM.SETTINGS.FIELDS.TABLE.CONTEXT'),
    width: '1fr',
  },
  {
    key: 'required',
    label: t('CRM.SETTINGS.FIELDS.TABLE.REQUIRED'),
    width: '0.7fr',
  },
  { key: 'actions', label: '', width: '104px', align: 'end' },
]);

const pipelineOptions = computed(() =>
  referencesStore.pipelines.map(pipeline => ({
    label: pipeline.name,
    value: pipeline.id,
  }))
);

const fieldTypeOptions = computed(() =>
  [
    'text',
    'textarea',
    'number',
    'currency',
    'percent',
    'checkbox',
    'date',
    'datetime',
    'select',
    'multiselect',
    'url',
  ].map(value => ({
    label: value,
    value,
  }))
);
const stageOutcomeOptions = computed(() => [
  { label: t('CRM.SETTINGS.STAGES.OUTCOMES.open'), value: 'open' },
  { label: t('CRM.SETTINGS.STAGES.OUTCOMES.won'), value: 'won' },
  { label: t('CRM.SETTINGS.STAGES.OUTCOMES.lost'), value: 'lost' },
]);

const taskStatusCategoryOptions = computed(() => [
  { label: t('CRM.SETTINGS.TASK_STATUSES.CATEGORIES.open'), value: 'open' },
  { label: t('CRM.SETTINGS.TASK_STATUSES.CATEGORIES.done'), value: 'done' },
]);

const contextOptions = computed(() => [
  {
    label: t('CRM.SETTINGS.FIELDS.CONTEXTS.standalone_task'),
    value: 'standalone_task',
  },
  {
    label: t('CRM.SETTINGS.FIELDS.CONTEXTS.deal_task'),
    value: 'deal_task',
  },
]);

const fieldContextsLabel = definition => {
  const contexts = definition.rules?.contexts || [];
  if (!contexts.length) {
    return t('CRM.SETTINGS.FIELDS.ALL_CONTEXTS');
  }

  const labelsByContext = {
    deal_task: t('CRM.SETTINGS.FIELDS.CONTEXTS.deal_task'),
    standalone_task: t('CRM.SETTINGS.FIELDS.CONTEXTS.standalone_task'),
  };

  return contexts
    .map(context => labelsByContext[context] || context)
    .join(', ');
};

const formatErrorMessage = error => formatCrmErrorMessage(error, t);

const resetPipelineForm = () => {
  Object.assign(pipelineForm, {
    active: true,
    code: '',
    default: false,
    id: null,
    name: '',
    position: '',
  });
};

const resetStageForm = () => {
  Object.assign(stageForm, {
    active: true,
    code: '',
    id: null,
    name: '',
    outcome: 'open',
    pipelineId: pipelineOptions.value[0]?.value || '',
    position: '',
  });
};

const resetTaskStatusForm = () => {
  Object.assign(taskStatusForm, {
    active: true,
    category: 'open',
    code: '',
    default: false,
    id: null,
    name: '',
    position: '',
  });
};

const resetFieldForm = () => {
  Object.assign(fieldForm, {
    active: true,
    contexts: [],
    defaultValue: '',
    description: '',
    entityKind: fieldEntityKind.value,
    fieldType: 'text',
    id: null,
    key: '',
    label: '',
    max: '',
    min: '',
    optionsText: '',
    position: '',
    regex: '',
    required: false,
  });
};

const openPipelineDrawer = pipeline => {
  if (pipeline) {
    Object.assign(pipelineForm, {
      active: pipeline.active,
      code: pipeline.code || '',
      default: pipeline.default,
      id: pipeline.id,
      name: pipeline.name,
      position: pipeline.position ?? '',
    });
  } else {
    resetPipelineForm();
  }

  pipelineDrawerOpen.value = true;
};

const openStageDrawer = ({ pipeline, stage } = {}) => {
  if (stage) {
    Object.assign(stageForm, {
      active: stage.active,
      code: stage.code || '',
      id: stage.id,
      name: stage.name,
      outcome: stage.outcome || 'open',
      pipelineId: stage.pipelineId,
      position: stage.position ?? '',
    });
  } else {
    resetStageForm();
    stageForm.pipelineId =
      pipeline?.id || pipelineOptions.value[0]?.value || '';
  }

  stageDrawerOpen.value = true;
};

const openTaskStatusDrawer = taskStatus => {
  if (taskStatus) {
    Object.assign(taskStatusForm, {
      active: taskStatus.active,
      category: taskStatus.category || 'open',
      code: taskStatus.code || '',
      default: taskStatus.default,
      id: taskStatus.id,
      name: taskStatus.name,
      position: taskStatus.position ?? '',
    });
  } else {
    resetTaskStatusForm();
  }

  taskStatusDrawerOpen.value = true;
};

const openFieldDrawer = fieldDefinition => {
  if (fieldDefinition) {
    const rawDefaultValue = fieldDefinition.defaultValue;
    let defaultValue = '';

    if (rawDefaultValue !== null && rawDefaultValue !== undefined) {
      defaultValue = Array.isArray(rawDefaultValue)
        ? rawDefaultValue.join(', ')
        : String(rawDefaultValue);
    }

    Object.assign(fieldForm, {
      active: fieldDefinition.active,
      contexts: fieldDefinition.rules?.contexts || [],
      defaultValue,
      description: fieldDefinition.description || '',
      entityKind: fieldDefinition.entityKind,
      fieldType: fieldDefinition.fieldType,
      id: fieldDefinition.id,
      key: fieldDefinition.key,
      label: fieldDefinition.label,
      max: fieldDefinition.rules?.max ?? '',
      min: fieldDefinition.rules?.min ?? '',
      optionsText: (fieldDefinition.options || [])
        .map(option => (typeof option === 'string' ? option : option.value))
        .join('\n'),
      position: fieldDefinition.position ?? '',
      regex: fieldDefinition.rules?.regex || '',
      required: fieldDefinition.required,
    });
  } else {
    resetFieldForm();
  }

  fieldDrawerOpen.value = true;
};

const savePipeline = async () => {
  try {
    await referencesStore.savePipeline({
      active: pipelineForm.active,
      code: pipelineForm.code || undefined,
      default: pipelineForm.default,
      id: pipelineForm.id,
      name: pipelineForm.name.trim(),
      position:
        pipelineForm.position === ''
          ? undefined
          : Number(pipelineForm.position),
    });
    useAlert(t('CRM.SETTINGS.PIPELINES.SUCCESS_SAVE'));
    pipelineDrawerOpen.value = false;
    resetPipelineForm();
  } catch (error) {
    useAlert(formatErrorMessage(error));
  }
};

const saveStage = async () => {
  try {
    await referencesStore.saveStage({
      active: stageForm.active,
      code: stageForm.code || undefined,
      id: stageForm.id,
      name: stageForm.name.trim(),
      outcome: stageForm.outcome,
      pipelineId: Number(stageForm.pipelineId),
      position:
        stageForm.position === '' ? undefined : Number(stageForm.position),
    });
    useAlert(t('CRM.SETTINGS.STAGES.SUCCESS_SAVE'));
    stageDrawerOpen.value = false;
    resetStageForm();
  } catch (error) {
    useAlert(formatErrorMessage(error));
  }
};

const saveTaskStatus = async () => {
  try {
    await referencesStore.saveTaskStatus({
      active: taskStatusForm.active,
      category: taskStatusForm.category,
      code: taskStatusForm.code || undefined,
      default: taskStatusForm.default,
      id: taskStatusForm.id,
      name: taskStatusForm.name.trim(),
      position:
        taskStatusForm.position === ''
          ? undefined
          : Number(taskStatusForm.position),
    });
    useAlert(t('CRM.SETTINGS.TASK_STATUSES.SUCCESS_SAVE'));
    taskStatusDrawerOpen.value = false;
    resetTaskStatusForm();
  } catch (error) {
    useAlert(formatErrorMessage(error));
  }
};

const parseFieldOptions = () => {
  return fieldForm.optionsText
    .split('\n')
    .map(option => option.trim())
    .filter(Boolean)
    .map(option => ({ label: option, value: option }));
};

const parseDefaultValue = () => {
  if (fieldForm.defaultValue === '') {
    return undefined;
  }

  if (fieldForm.fieldType === 'checkbox') {
    return ['true', '1', 'yes'].includes(
      String(fieldForm.defaultValue).toLowerCase()
    );
  }

  if (['currency', 'number', 'percent'].includes(fieldForm.fieldType)) {
    return Number(fieldForm.defaultValue);
  }

  if (fieldForm.fieldType === 'multiselect') {
    return fieldForm.defaultValue
      .split(',')
      .map(value => value.trim())
      .filter(Boolean);
  }

  return fieldForm.defaultValue;
};

const saveFieldDefinition = async () => {
  try {
    const previousEntityKind = fieldForm.id
      ? selectedFieldDefinitions.value.find(
          definition => Number(definition.id) === Number(fieldForm.id)
        )?.entityKind
      : null;

    await referencesStore.saveFieldDefinition({
      active: fieldForm.active,
      default_value: parseDefaultValue(),
      description: fieldForm.description || undefined,
      entity_kind: fieldForm.entityKind,
      field_type: fieldForm.fieldType,
      id: fieldForm.id,
      key: fieldForm.key,
      label: fieldForm.label.trim(),
      options: ['select', 'multiselect'].includes(fieldForm.fieldType)
        ? parseFieldOptions()
        : [],
      position:
        fieldForm.position === '' ? undefined : Number(fieldForm.position),
      required: fieldForm.required,
      rules: {
        ...(fieldForm.min !== '' ? { min: Number(fieldForm.min) } : {}),
        ...(fieldForm.max !== '' ? { max: Number(fieldForm.max) } : {}),
        ...(fieldForm.regex ? { regex: fieldForm.regex } : {}),
        ...(fieldForm.entityKind === 'task' && fieldForm.contexts.length
          ? { contexts: fieldForm.contexts }
          : {}),
      },
    });
    useAlert(t('CRM.SETTINGS.FIELDS.SUCCESS_SAVE'));
    fieldDrawerOpen.value = false;
    resetFieldForm();
    const entityKindsToRefresh = [
      previousEntityKind,
      fieldForm.entityKind,
      fieldEntityKind.value,
    ].filter((value, index, array) => value && array.indexOf(value) === index);

    await Promise.all(
      entityKindsToRefresh.map(entityKind =>
        referencesStore.loadFieldDefinitions(entityKind)
      )
    );
  } catch (error) {
    useAlert(formatErrorMessage(error));
  }
};

const removeFieldDefinition = async fieldDefinition => {
  // eslint-disable-next-line no-alert
  if (!window.confirm(t('CRM.SETTINGS.FIELDS.DELETE_CONFIRM'))) return;

  try {
    await referencesStore.deleteFieldDefinition(fieldDefinition);
    useAlert(t('CRM.SETTINGS.FIELDS.SUCCESS_DELETE'));
  } catch (error) {
    useAlert(formatErrorMessage(error));
  }
};

onMounted(async () => {
  fieldEntityKind.value = dealsEnabled.value ? 'deal' : 'task';

  const requests = [];

  if (dealsEnabled.value) {
    requests.push(referencesStore.loadPipelines());
    requests.push(referencesStore.loadFieldDefinitions('deal'));
  }

  if (tasksEnabled.value) {
    requests.push(referencesStore.loadTaskStatuses());
    requests.push(referencesStore.loadFieldDefinitions('task'));
  }

  await Promise.all(requests);
  resetStageForm();
  resetFieldForm();
});
</script>

<template>
  <SettingsLayout
    :is-loading="
      referencesStore.ui.isLoadingPipelines ||
      referencesStore.ui.isLoadingTaskStatuses ||
      referencesStore.ui.isLoadingFieldDefinitions
    "
    :loading-message="$t('CRM.SETTINGS.LOADING')"
  >
    <template #header>
      <BaseSettingsHeader
        :title="$t('CRM.SETTINGS.TITLE')"
        :description="$t('CRM.SETTINGS.DESCRIPTION')"
      />
    </template>

    <template #loading>
      <div class="flex justify-center py-16">
        <Spinner class="!h-8 !w-8" />
      </div>
    </template>

    <template #body>
      <div class="grid gap-6">
        <SchedulingErrorState
          v-if="referencesStore.ui.error"
          :title="$t('CRM.ERRORS.LOAD_TITLE')"
          :description="formatErrorMessage(referencesStore.ui.error)"
          @retry="$router.go(0)"
        />

        <SchedulingFormFieldGroup
          v-if="dealsEnabled"
          :title="$t('CRM.SETTINGS.PIPELINES.TITLE')"
          :description="$t('CRM.SETTINGS.PIPELINES.DESCRIPTION')"
        >
          <SchedulingRecordTable
            :columns="pipelineColumns"
            :rows="referencesStore.pipelines"
          >
            <template #headerActions>
              <div />
            </template>
            <template #cell-name="{ row }">
              <div class="grid gap-1">
                <span class="font-medium text-n-slate-12">{{ row.name }}</span>
                <span class="text-xs text-n-slate-11">{{
                  row.code || '—'
                }}</span>
              </div>
            </template>
            <template #cell-default="{ row }">
              <span class="text-sm text-n-slate-12">
                {{
                  row.default ? $t('CRM.GENERAL.DEFAULT') : $t('CRM.GENERAL.NO')
                }}
              </span>
            </template>
            <template #cell-status="{ row }">
              <span class="text-sm text-n-slate-12">
                {{
                  row.active
                    ? $t('CRM.GENERAL.ACTIVE')
                    : $t('CRM.GENERAL.INACTIVE')
                }}
              </span>
            </template>
            <template #cell-stages="{ row }">
              <div class="flex flex-wrap gap-2">
                <button
                  v-for="stage in row.stages"
                  :key="stage.id"
                  type="button"
                  class="rounded-full bg-n-alpha-black2 px-2 py-1 text-xs text-n-slate-12 outline outline-1 outline-n-weak"
                  @click="openStageDrawer({ stage })"
                >
                  {{ stage.name }}
                </button>
              </div>
            </template>
            <template #cell-actions="{ row }">
              <div class="flex justify-end gap-1">
                <Button
                  v-if="canManage"
                  size="sm"
                  color="slate"
                  variant="ghost"
                  icon="i-lucide-plus"
                  @click="openStageDrawer({ pipeline: row })"
                />
                <Button
                  v-if="canManage"
                  size="sm"
                  color="slate"
                  variant="ghost"
                  icon="i-lucide-pen-line"
                  @click="openPipelineDrawer(row)"
                />
              </div>
            </template>
          </SchedulingRecordTable>

          <template #headerActions>
            <Button
              v-if="canManage"
              size="sm"
              icon="i-lucide-plus"
              :label="$t('CRM.SETTINGS.PIPELINES.ADD')"
              @click="openPipelineDrawer()"
            />
          </template>
        </SchedulingFormFieldGroup>

        <SchedulingFormFieldGroup
          v-if="tasksEnabled"
          :title="$t('CRM.SETTINGS.TASK_STATUSES.TITLE')"
          :description="$t('CRM.SETTINGS.TASK_STATUSES.DESCRIPTION')"
        >
          <SchedulingRecordTable
            :columns="taskStatusColumns"
            :rows="referencesStore.taskStatuses"
          >
            <template #cell-name="{ row }">
              <div class="grid gap-1">
                <span class="font-medium text-n-slate-12">{{ row.name }}</span>
                <span class="text-xs text-n-slate-11">{{
                  row.code || '—'
                }}</span>
              </div>
            </template>
            <template #cell-category="{ row }">
              <span class="text-sm text-n-slate-12">{{ row.category }}</span>
            </template>
            <template #cell-default="{ row }">
              <span class="text-sm text-n-slate-12">
                {{
                  row.default ? $t('CRM.GENERAL.DEFAULT') : $t('CRM.GENERAL.NO')
                }}
              </span>
            </template>
            <template #cell-status="{ row }">
              <span class="text-sm text-n-slate-12">
                {{
                  row.active
                    ? $t('CRM.GENERAL.ACTIVE')
                    : $t('CRM.GENERAL.INACTIVE')
                }}
              </span>
            </template>
            <template #cell-actions="{ row }">
              <Button
                v-if="canManage"
                size="sm"
                color="slate"
                variant="ghost"
                icon="i-lucide-pen-line"
                @click="openTaskStatusDrawer(row)"
              />
            </template>
          </SchedulingRecordTable>

          <template #headerActions>
            <Button
              v-if="canManage"
              size="sm"
              icon="i-lucide-plus"
              :label="$t('CRM.SETTINGS.TASK_STATUSES.ADD')"
              @click="openTaskStatusDrawer()"
            />
          </template>
        </SchedulingFormFieldGroup>

        <SchedulingFormFieldGroup
          :title="$t('CRM.SETTINGS.FIELDS.TITLE')"
          :description="$t('CRM.SETTINGS.FIELDS.DESCRIPTION')"
        >
          <div class="grid gap-4">
            <div class="flex items-center justify-between gap-3">
              <SchedulingViewSwitcher
                v-model="fieldEntityKind"
                :views="fieldTabs"
              />
              <Button
                v-if="canManage"
                size="sm"
                icon="i-lucide-plus"
                :label="$t('CRM.SETTINGS.FIELDS.ADD')"
                @click="openFieldDrawer()"
              />
            </div>

            <SchedulingRecordTable
              :columns="fieldColumns"
              :rows="selectedFieldDefinitions"
            >
              <template #cell-label="{ row }">
                <div class="grid gap-1">
                  <span class="font-medium text-n-slate-12">{{
                    row.label
                  }}</span>
                  <span class="text-xs text-n-slate-11">{{
                    row.description || '—'
                  }}</span>
                </div>
              </template>
              <template #cell-key="{ row }">
                <span class="text-sm text-n-slate-12">{{ row.key }}</span>
              </template>
              <template #cell-fieldType="{ row }">
                <span class="text-sm text-n-slate-12">{{ row.fieldType }}</span>
              </template>
              <template #cell-context="{ row }">
                <span class="text-sm text-n-slate-12">
                  {{ fieldContextsLabel(row) }}
                </span>
              </template>
              <template #cell-required="{ row }">
                <span class="text-sm text-n-slate-12">
                  {{
                    row.required ? $t('CRM.GENERAL.YES') : $t('CRM.GENERAL.NO')
                  }}
                </span>
              </template>
              <template #cell-actions="{ row }">
                <div class="flex justify-end gap-1">
                  <Button
                    v-if="canManage"
                    size="sm"
                    color="slate"
                    variant="ghost"
                    icon="i-lucide-pen-line"
                    @click="openFieldDrawer(row)"
                  />
                  <Button
                    v-if="canManage"
                    size="sm"
                    color="slate"
                    variant="ghost"
                    icon="i-lucide-trash"
                    @click="removeFieldDefinition(row)"
                  />
                </div>
              </template>
            </SchedulingRecordTable>
          </div>
        </SchedulingFormFieldGroup>
      </div>
    </template>

    <SchedulingDrawer
      v-model="pipelineDrawerOpen"
      :title="
        pipelineForm.id
          ? $t('CRM.SETTINGS.PIPELINES.EDIT_TITLE')
          : $t('CRM.SETTINGS.PIPELINES.CREATE_TITLE')
      "
      :confirm-label="$t('CRM.GENERAL.SAVE')"
      :is-loading="referencesStore.ui.isSaving"
      :disable-confirm="!pipelineForm.name.trim()"
      @confirm="savePipeline"
    >
      <div class="grid gap-4">
        <Input
          :label="$t('CRM.SETTINGS.PIPELINES.FORM.NAME')"
          :model-value="pipelineForm.name"
          @update:model-value="pipelineForm.name = $event"
        />
        <Input
          :label="$t('CRM.SETTINGS.PIPELINES.FORM.CODE')"
          :model-value="pipelineForm.code"
          @update:model-value="pipelineForm.code = $event"
        />
        <Input
          :label="$t('CRM.SETTINGS.PIPELINES.FORM.POSITION')"
          :model-value="pipelineForm.position"
          type="number"
          @update:model-value="pipelineForm.position = $event"
        />
        <div class="flex items-center gap-3">
          <Checkbox
            :model-value="pipelineForm.active"
            @update:model-value="pipelineForm.active = $event"
          />
          <span class="text-sm text-n-slate-12">
            {{ $t('CRM.SETTINGS.PIPELINES.FORM.ACTIVE') }}
          </span>
        </div>
        <div class="flex items-center gap-3">
          <Checkbox
            :model-value="pipelineForm.default"
            @update:model-value="pipelineForm.default = $event"
          />
          <span class="text-sm text-n-slate-12">
            {{ $t('CRM.SETTINGS.PIPELINES.FORM.DEFAULT') }}
          </span>
        </div>
      </div>
    </SchedulingDrawer>

    <SchedulingDrawer
      v-model="stageDrawerOpen"
      :title="
        stageForm.id
          ? $t('CRM.SETTINGS.STAGES.EDIT_TITLE')
          : $t('CRM.SETTINGS.STAGES.CREATE_TITLE')
      "
      :confirm-label="$t('CRM.GENERAL.SAVE')"
      :is-loading="referencesStore.ui.isSaving"
      :disable-confirm="!stageForm.name.trim() || !stageForm.pipelineId"
      @confirm="saveStage"
    >
      <div class="grid gap-4">
        <SchedulingSelectField
          :label="$t('CRM.SETTINGS.STAGES.FORM.PIPELINE')"
          :model-value="stageForm.pipelineId"
          :options="pipelineOptions"
          :disabled="Boolean(stageForm.id)"
          @update:model-value="stageForm.pipelineId = $event"
        />
        <Input
          :label="$t('CRM.SETTINGS.STAGES.FORM.NAME')"
          :model-value="stageForm.name"
          @update:model-value="stageForm.name = $event"
        />
        <Input
          :label="$t('CRM.SETTINGS.STAGES.FORM.CODE')"
          :model-value="stageForm.code"
          @update:model-value="stageForm.code = $event"
        />
        <SchedulingSelectField
          :label="$t('CRM.SETTINGS.STAGES.FORM.OUTCOME')"
          :model-value="stageForm.outcome"
          :options="stageOutcomeOptions"
          @update:model-value="stageForm.outcome = $event"
        />
        <Input
          :label="$t('CRM.SETTINGS.STAGES.FORM.POSITION')"
          :model-value="stageForm.position"
          type="number"
          @update:model-value="stageForm.position = $event"
        />
        <div class="flex items-center gap-3">
          <Checkbox
            :model-value="stageForm.active"
            @update:model-value="stageForm.active = $event"
          />
          <span class="text-sm text-n-slate-12">
            {{ $t('CRM.SETTINGS.STAGES.FORM.ACTIVE') }}
          </span>
        </div>
      </div>
    </SchedulingDrawer>

    <SchedulingDrawer
      v-model="taskStatusDrawerOpen"
      :title="
        taskStatusForm.id
          ? $t('CRM.SETTINGS.TASK_STATUSES.EDIT_TITLE')
          : $t('CRM.SETTINGS.TASK_STATUSES.CREATE_TITLE')
      "
      :confirm-label="$t('CRM.GENERAL.SAVE')"
      :is-loading="referencesStore.ui.isSaving"
      :disable-confirm="!taskStatusForm.name.trim()"
      @confirm="saveTaskStatus"
    >
      <div class="grid gap-4">
        <Input
          :label="$t('CRM.SETTINGS.TASK_STATUSES.FORM.NAME')"
          :model-value="taskStatusForm.name"
          @update:model-value="taskStatusForm.name = $event"
        />
        <Input
          :label="$t('CRM.SETTINGS.TASK_STATUSES.FORM.CODE')"
          :model-value="taskStatusForm.code"
          @update:model-value="taskStatusForm.code = $event"
        />
        <SchedulingSelectField
          :label="$t('CRM.SETTINGS.TASK_STATUSES.FORM.CATEGORY')"
          :model-value="taskStatusForm.category"
          :options="taskStatusCategoryOptions"
          @update:model-value="taskStatusForm.category = $event"
        />
        <Input
          :label="$t('CRM.SETTINGS.TASK_STATUSES.FORM.POSITION')"
          :model-value="taskStatusForm.position"
          type="number"
          @update:model-value="taskStatusForm.position = $event"
        />
        <div class="flex items-center gap-3">
          <Checkbox
            :model-value="taskStatusForm.active"
            @update:model-value="taskStatusForm.active = $event"
          />
          <span class="text-sm text-n-slate-12">
            {{ $t('CRM.SETTINGS.TASK_STATUSES.FORM.ACTIVE') }}
          </span>
        </div>
        <div class="flex items-center gap-3">
          <Checkbox
            :model-value="taskStatusForm.default"
            @update:model-value="taskStatusForm.default = $event"
          />
          <span class="text-sm text-n-slate-12">
            {{ $t('CRM.SETTINGS.TASK_STATUSES.FORM.DEFAULT') }}
          </span>
        </div>
      </div>
    </SchedulingDrawer>

    <SchedulingDrawer
      v-model="fieldDrawerOpen"
      width="xl"
      :title="
        fieldForm.id
          ? $t('CRM.SETTINGS.FIELDS.EDIT_TITLE')
          : $t('CRM.SETTINGS.FIELDS.CREATE_TITLE')
      "
      :confirm-label="$t('CRM.GENERAL.SAVE')"
      :is-loading="referencesStore.ui.isSaving"
      :disable-confirm="!fieldForm.label.trim() || !fieldForm.key.trim()"
      @confirm="saveFieldDefinition"
    >
      <div class="grid gap-4">
        <SchedulingFormFieldGroup
          :title="$t('CRM.SETTINGS.FIELDS.FORM.BASICS')"
          :description="$t('CRM.SETTINGS.FIELDS.FORM.BASICS_DESCRIPTION')"
        >
          <div class="grid gap-4 md:grid-cols-2">
            <SchedulingSelectField
              :label="$t('CRM.SETTINGS.FIELDS.FORM.ENTITY')"
              :model-value="fieldForm.entityKind"
              :options="fieldTabs"
              @update:model-value="fieldForm.entityKind = $event"
            />
            <SchedulingSelectField
              :label="$t('CRM.SETTINGS.FIELDS.FORM.TYPE')"
              :model-value="fieldForm.fieldType"
              :options="fieldTypeOptions"
              @update:model-value="fieldForm.fieldType = $event"
            />
            <Input
              :label="$t('CRM.SETTINGS.FIELDS.FORM.LABEL')"
              :model-value="fieldForm.label"
              @update:model-value="fieldForm.label = $event"
            />
            <Input
              :label="$t('CRM.SETTINGS.FIELDS.FORM.KEY')"
              :model-value="fieldForm.key"
              @update:model-value="fieldForm.key = $event"
            />
            <Input
              :label="$t('CRM.SETTINGS.FIELDS.FORM.POSITION')"
              :model-value="fieldForm.position"
              type="number"
              @update:model-value="fieldForm.position = $event"
            />
            <Input
              :label="$t('CRM.SETTINGS.FIELDS.FORM.DEFAULT_VALUE')"
              :model-value="fieldForm.defaultValue"
              @update:model-value="fieldForm.defaultValue = $event"
            />
            <TextArea
              class="md:col-span-2"
              :label="$t('CRM.SETTINGS.FIELDS.FORM.DESCRIPTION')"
              :model-value="fieldForm.description"
              auto-height
              @update:model-value="fieldForm.description = $event"
            />
          </div>
        </SchedulingFormFieldGroup>

        <SchedulingFormFieldGroup
          :title="$t('CRM.SETTINGS.FIELDS.FORM.RULES')"
          :description="$t('CRM.SETTINGS.FIELDS.FORM.RULES_DESCRIPTION')"
        >
          <div class="grid gap-4 md:grid-cols-2">
            <Input
              :label="$t('CRM.SETTINGS.FIELDS.FORM.MIN')"
              :model-value="fieldForm.min"
              type="number"
              @update:model-value="fieldForm.min = $event"
            />
            <Input
              :label="$t('CRM.SETTINGS.FIELDS.FORM.MAX')"
              :model-value="fieldForm.max"
              type="number"
              @update:model-value="fieldForm.max = $event"
            />
            <Input
              class="md:col-span-2"
              :label="$t('CRM.SETTINGS.FIELDS.FORM.REGEX')"
              :model-value="fieldForm.regex"
              @update:model-value="fieldForm.regex = $event"
            />
            <div
              v-if="['select', 'multiselect'].includes(fieldForm.fieldType)"
              class="md:col-span-2"
            >
              <TextArea
                :label="$t('CRM.SETTINGS.FIELDS.FORM.OPTIONS')"
                :model-value="fieldForm.optionsText"
                :placeholder="
                  $t('CRM.SETTINGS.FIELDS.FORM.OPTIONS_PLACEHOLDER')
                "
                auto-height
                @update:model-value="fieldForm.optionsText = $event"
              />
            </div>
            <div
              v-if="fieldForm.entityKind === 'task'"
              class="md:col-span-2 grid gap-1"
            >
              <span class="mb-0.5 text-sm font-medium text-n-slate-12">
                {{ $t('CRM.SETTINGS.FIELDS.FORM.CONTEXTS') }}
              </span>
              <TagMultiSelectComboBox
                :model-value="fieldForm.contexts"
                :options="contextOptions"
                @update:model-value="fieldForm.contexts = $event"
              />
            </div>
            <div class="flex items-center gap-3">
              <Checkbox
                :model-value="fieldForm.required"
                @update:model-value="fieldForm.required = $event"
              />
              <span class="text-sm text-n-slate-12">
                {{ $t('CRM.SETTINGS.FIELDS.FORM.REQUIRED') }}
              </span>
            </div>
            <div class="flex items-center gap-3">
              <Checkbox
                :model-value="fieldForm.active"
                @update:model-value="fieldForm.active = $event"
              />
              <span class="text-sm text-n-slate-12">
                {{ $t('CRM.SETTINGS.FIELDS.FORM.ACTIVE') }}
              </span>
            </div>
          </div>
        </SchedulingFormFieldGroup>
      </div>
    </SchedulingDrawer>
  </SettingsLayout>
</template>
