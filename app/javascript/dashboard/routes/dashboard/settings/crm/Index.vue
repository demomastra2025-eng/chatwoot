<script setup>
import { computed, onMounted, reactive, ref, watch } from 'vue';
import { useI18n } from 'vue-i18n';
import { useRoute, useRouter } from 'vue-router';
import Draggable from 'vuedraggable';

import { useAlert } from 'dashboard/composables';
import { useMapGetter } from 'dashboard/composables/store';
import { usePolicy } from 'dashboard/composables/usePolicy';
import { FEATURE_FLAGS } from 'dashboard/featureFlags';
import Button from 'dashboard/components-next/button/Button.vue';
import Checkbox from 'dashboard/components-next/checkbox/Checkbox.vue';
import Dialog from 'dashboard/components-next/dialog/Dialog.vue';
import Input from 'dashboard/components-next/input/Input.vue';
import Spinner from 'dashboard/components-next/spinner/Spinner.vue';
import Switch from 'dashboard/components-next/switch/Switch.vue';
import SchedulingDrawer from 'dashboard/components-next/Scheduling/SchedulingDrawer.vue';
import SchedulingColorPicker from 'dashboard/components-next/Scheduling/SchedulingColorPicker.vue';
import SchedulingErrorState from 'dashboard/components-next/Scheduling/SchedulingErrorState.vue';
import SchedulingFormFieldGroup from 'dashboard/components-next/Scheduling/SchedulingFormFieldGroup.vue';
import SchedulingSelectField from 'dashboard/components-next/Scheduling/SchedulingSelectField.vue';
import BaseSettingsHeader from '../components/BaseSettingsHeader.vue';
import SettingsLayout from '../SettingsLayout.vue';
import { useCrmReferencesStore } from 'dashboard/stores/crm/references';
import { formatCrmErrorMessage } from 'dashboard/stores/crm/shared';
import {
  DEFAULT_STAGE_COLOR,
  STAGE_STANDARD_COLORS,
  getUnavailableStageColors,
  pickStageColor,
} from 'dashboard/stores/crm/stageColors';
import {
  DEFAULT_TASK_STATUS_COLOR,
  TASK_STATUS_STANDARD_COLORS,
  getUnavailableTaskStatusColors,
  pickTaskStatusColor,
} from 'dashboard/stores/crm/taskStatusColors';

const referencesStore = useCrmReferencesStore();
const route = useRoute();
const router = useRouter();
const { checkPermissions } = usePolicy();
const { t } = useI18n();
const normalizedDefaultStageColor = String(DEFAULT_STAGE_COLOR || '')
  .trim()
  .toUpperCase();
const normalizedDefaultTaskStatusColor = String(DEFAULT_TASK_STATUS_COLOR || '')
  .trim()
  .toUpperCase();

const stageDrawerOpen = ref(false);
const stageOrderDrawerOpen = ref(false);
const stageOrderSaving = ref(false);
const stageOrderPipeline = ref(null);
const stageOrderRows = ref([]);
const taskStatusDrawerOpen = ref(false);
const taskStatusDeleteDialogRef = ref(null);
const taskStatusPendingDelete = ref(null);
const taskStatusRows = ref([]);
const draggingTaskStatuses = ref(false);
const taskStatusOrderSaving = ref(false);
const pipelineDeleteDialogRef = ref(null);
const pipelinePendingDelete = ref(null);
const stageDeleteDialogRef = ref(null);
const stagePendingDelete = ref(null);
const showArchivedPipelines = ref(false);
const pipelineNameDrafts = reactive({});
const pipelineLastSyncedNames = reactive({});
const pipelineSavingIds = reactive({});
const pipelineRows = ref([]);
const draggingPipelines = ref(false);
const pipelineOrderSaving = ref(false);
const newPipelineDraft = ref(null);
const pipelineCreateSaving = ref(false);

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

const stageForm = reactive({
  active: true,
  code: '',
  color: DEFAULT_STAGE_COLOR,
  id: null,
  name: '',
  outcome: 'open',
  pipelineId: '',
  position: '',
});

const taskStatusForm = reactive({
  active: true,
  category: 'open',
  color: DEFAULT_TASK_STATUS_COLOR,
  id: null,
  name: '',
});

const pipelineColumns = computed(() => [
  {
    key: 'name',
    label: t('CRM.SETTINGS.PIPELINES.TABLE.NAME'),
    width: '1.15fr',
  },
  {
    key: 'default',
    label: t('CRM.SETTINGS.PIPELINES.TABLE.DEFAULT'),
    width: '0.9fr',
  },
  {
    key: 'stages',
    label: t('CRM.SETTINGS.PIPELINES.TABLE.STAGES'),
    width: '2.05fr',
  },
  { key: 'actions', label: '', width: '208px', align: 'end' },
]);

const visiblePipelines = computed(() =>
  referencesStore.pipelines.filter(
    pipeline => showArchivedPipelines.value || pipeline.active
  )
);

const pipelineGridTemplate = computed(() =>
  pipelineColumns.value
    .map(column => {
      const width = String(column.width || '1fr');
      return width.endsWith('fr') ? `minmax(0, ${width})` : width;
    })
    .join(' ')
);

const taskStatusColumns = computed(() => [
  {
    key: 'name',
    label: t('CRM.SETTINGS.TASK_STATUSES.TABLE.NAME'),
    width: '1.3fr',
  },
  {
    key: 'category',
    label: t('CRM.SETTINGS.TASK_STATUSES.TABLE.CATEGORY'),
    width: '0.9fr',
  },
  {
    key: 'default',
    label: t('CRM.SETTINGS.TASK_STATUSES.TABLE.DEFAULT'),
    width: '0.8fr',
  },
  { key: 'actions', label: '', width: '116px', align: 'end' },
]);

const taskStatusGridTemplate = computed(() =>
  taskStatusColumns.value
    .map(column => {
      const width = String(column.width || '1fr');
      return width.endsWith('fr') ? `minmax(0, ${width})` : width;
    })
    .join(' ')
);

const pipelineOptions = computed(() =>
  referencesStore.pipelines.map(pipeline => ({
    label: pipeline.name,
    value: pipeline.id,
  }))
);
const stageOutcomeOptions = computed(() => [
  { label: t('CRM.SETTINGS.STAGES.OUTCOMES.open'), value: 'open' },
  { label: t('CRM.SETTINGS.STAGES.OUTCOMES.won'), value: 'won' },
  { label: t('CRM.SETTINGS.STAGES.OUTCOMES.lost'), value: 'lost' },
]);

const taskStatusCategoryOptions = computed(() => [
  { label: t('CRM.SETTINGS.TASK_STATUSES.CATEGORIES.open'), value: 'open' },
  {
    label: t('CRM.SETTINGS.TASK_STATUSES.CATEGORIES.in_progress'),
    value: 'in_progress',
  },
  { label: t('CRM.SETTINGS.TASK_STATUSES.CATEGORIES.done'), value: 'done' },
]);

const taskStatusCategoryLabel = category => {
  const labelsByCategory = {
    open: t('CRM.SETTINGS.TASK_STATUSES.CATEGORIES.open'),
    in_progress: t('CRM.SETTINGS.TASK_STATUSES.CATEGORIES.in_progress'),
    done: t('CRM.SETTINGS.TASK_STATUSES.CATEGORIES.done'),
  };

  return labelsByCategory[category] || category;
};

const formatErrorMessage = error => formatCrmErrorMessage(error, t);

watch(
  () =>
    referencesStore.pipelines.map(pipeline => ({
      id: String(pipeline.id),
      name: pipeline.name,
    })),
  pipelines => {
    const nextIds = new Set(pipelines.map(pipeline => pipeline.id));

    pipelines.forEach(pipeline => {
      const previousName = pipelineLastSyncedNames[pipeline.id];
      const currentDraft = pipelineNameDrafts[pipeline.id];

      if (
        currentDraft === undefined ||
        currentDraft === previousName ||
        previousName === undefined
      ) {
        pipelineNameDrafts[pipeline.id] = pipeline.name;
      }

      pipelineLastSyncedNames[pipeline.id] = pipeline.name;
    });

    Object.keys(pipelineNameDrafts).forEach(id => {
      if (!nextIds.has(id)) {
        delete pipelineNameDrafts[id];
      }
    });

    Object.keys(pipelineLastSyncedNames).forEach(id => {
      if (!nextIds.has(id)) {
        delete pipelineLastSyncedNames[id];
      }
    });
  },
  { immediate: true }
);

watch(
  visiblePipelines,
  pipelines => {
    if (draggingPipelines.value || pipelineOrderSaving.value) {
      return;
    }

    pipelineRows.value = [...pipelines];
  },
  { immediate: true }
);

watch(
  () => referencesStore.taskStatuses,
  taskStatuses => {
    if (draggingTaskStatuses.value || taskStatusOrderSaving.value) {
      return;
    }

    taskStatusRows.value = [...taskStatuses];
  },
  { immediate: true }
);

const pipelineRowClass = pipeline =>
  pipeline.active
    ? ''
    : 'bg-n-slate-2/70 text-n-slate-10 hover:!bg-n-slate-2/80';

const pipelineSubtextClass = pipeline =>
  pipeline.active ? 'text-n-slate-11' : 'text-n-slate-9';

const pipelineNameInputClass = pipeline =>
  pipeline.active
    ? 'font-medium shadow-none !bg-n-solid-1'
    : 'font-medium shadow-none !bg-n-slate-2 !text-n-slate-10';

const isPipelineSaving = pipelineId => Boolean(pipelineSavingIds[pipelineId]);

const setPipelineSaving = (pipelineId, isSaving) => {
  if (isSaving) {
    pipelineSavingIds[pipelineId] = true;
    return;
  }

  delete pipelineSavingIds[pipelineId];
};

const syncPipelineRows = () => {
  pipelineRows.value = [...visiblePipelines.value];
};

const buildPipelineSavePayload = (pipeline, overrides = {}) => ({
  active: overrides.active ?? pipeline.active,
  code: (overrides.code ?? pipeline.code) || undefined,
  default: overrides.default ?? pipeline.default,
  id: pipeline.id,
  name:
    overrides.name ??
    String(
      pipelineNameDrafts[String(pipeline.id)] ?? pipeline.name ?? ''
    ).trim(),
  position:
    overrides.position ??
    (pipeline.position === '' || pipeline.position === undefined
      ? undefined
      : Number(pipeline.position)),
});

const persistInlinePipeline = async (pipeline, overrides = {}) => {
  const pipelineId = String(pipeline.id);
  setPipelineSaving(pipelineId, true);

  try {
    const savedPipeline = await referencesStore.savePipeline(
      buildPipelineSavePayload(pipeline, overrides)
    );
    pipelineNameDrafts[pipelineId] = savedPipeline.name;
    pipelineLastSyncedNames[pipelineId] = savedPipeline.name;
    return savedPipeline;
  } catch (error) {
    pipelineNameDrafts[pipelineId] = pipeline.name;
    useAlert(formatErrorMessage(error));
    throw error;
  } finally {
    setPipelineSaving(pipelineId, false);
  }
};

const saveInlinePipelineName = async pipeline => {
  const pipelineId = String(pipeline.id);
  if (isPipelineSaving(pipelineId)) return;

  const nextName = String(
    pipelineNameDrafts[pipelineId] ?? pipeline.name ?? ''
  ).trim();
  const currentName = String(pipeline.name || '').trim();

  if (!nextName) {
    pipelineNameDrafts[pipelineId] = currentName;
    return;
  }

  if (nextName === currentName) {
    pipelineNameDrafts[pipelineId] = currentName;
    return;
  }

  await persistInlinePipeline(pipeline, { name: nextName });
};

const saveInlinePipelineDefault = async (pipeline, nextDefault) => {
  if (isPipelineSaving(String(pipeline.id))) return;
  if (!pipeline.active) return;
  await persistInlinePipeline(pipeline, {
    default: nextDefault,
    name: pipeline.name,
  });
};

const toggleInlinePipelineArchived = async (pipeline, nextActive) => {
  if (isPipelineSaving(String(pipeline.id))) return;

  await persistInlinePipeline(pipeline, {
    active: nextActive,
    default: nextActive ? pipeline.default : false,
    name: pipeline.name,
  });

  useAlert(
    nextActive
      ? t('CRM.SETTINGS.PIPELINES.SUCCESS_RESTORED')
      : t('CRM.SETTINGS.PIPELINES.SUCCESS_ARCHIVED')
  );
};

const openDeletePipelineDialog = pipeline => {
  if (!pipeline || pipeline.active) return;

  pipelinePendingDelete.value = pipeline;
  pipelineDeleteDialogRef.value?.open();
};

const closeDeletePipelineDialog = () => {
  pipelinePendingDelete.value = null;
};

const deletePipeline = async () => {
  if (!pipelinePendingDelete.value) return;

  try {
    await referencesStore.deletePipeline(pipelinePendingDelete.value);
    pipelineDeleteDialogRef.value?.close();
    useAlert(t('CRM.SETTINGS.PIPELINES.SUCCESS_DELETE'));
  } catch (error) {
    useAlert(formatErrorMessage(error));
  }
};

const canToggleTaskStatusDefault = taskStatus =>
  taskStatus.category === 'open' && taskStatus.active;

const saveInlineTaskStatusDefault = async (taskStatus, nextDefault) => {
  try {
    await referencesStore.saveTaskStatus({
      id: taskStatus.id,
      default: nextDefault,
    });
  } catch (error) {
    useAlert(formatErrorMessage(error));
  }
};

const handleTaskStatusDragStart = () => {
  draggingTaskStatuses.value = true;
};

const syncTaskStatusRows = () => {
  taskStatusRows.value = [...referencesStore.taskStatuses];
};

const persistTaskStatusOrder = async () => {
  taskStatusOrderSaving.value = true;

  try {
    const taskStatusUpdates = taskStatusRows.value
      .map((taskStatus, index) => ({
        ...taskStatus,
        nextPosition: index,
      }))
      .filter(
        taskStatus => Number(taskStatus.position) !== taskStatus.nextPosition
      );

    await Promise.all(
      taskStatusUpdates.map(taskStatus =>
        referencesStore.saveTaskStatus({
          id: taskStatus.id,
          position: taskStatus.nextPosition,
        })
      )
    );

    await referencesStore.loadTaskStatuses();
  } catch (error) {
    useAlert(formatErrorMessage(error));
    await referencesStore.loadTaskStatuses();
  } finally {
    taskStatusOrderSaving.value = false;
    draggingTaskStatuses.value = false;
    syncTaskStatusRows();
  }
};

const handleTaskStatusDragEnd = async event => {
  if (event.oldIndex === event.newIndex) {
    draggingTaskStatuses.value = false;
    syncTaskStatusRows();
    return;
  }

  await persistTaskStatusOrder();
};

const persistPipelineOrder = async () => {
  pipelineOrderSaving.value = true;

  try {
    const orderedVisiblePipelines = [...pipelineRows.value];
    const visibleIds = new Set(
      orderedVisiblePipelines.map(pipeline => Number(pipeline.id))
    );
    const hiddenPipelines = [...referencesStore.pipelines]
      .filter(pipeline => !visibleIds.has(Number(pipeline.id)))
      .sort((left, right) => left.position - right.position);
    const nextPipelineOrder = [...orderedVisiblePipelines, ...hiddenPipelines];

    const pipelineUpdates = nextPipelineOrder
      .map((pipeline, index) => ({
        ...pipeline,
        nextPosition: index,
      }))
      .filter(pipeline => Number(pipeline.position) !== pipeline.nextPosition);

    await Promise.all(
      pipelineUpdates.map(pipeline =>
        referencesStore.savePipeline({
          active: pipeline.active,
          code: pipeline.code || undefined,
          default: pipeline.default,
          id: pipeline.id,
          name: pipeline.name,
          position: pipeline.nextPosition,
        })
      )
    );

    await referencesStore.loadPipelines();
  } catch (error) {
    useAlert(formatErrorMessage(error));
    await referencesStore.loadPipelines();
  } finally {
    pipelineOrderSaving.value = false;
    draggingPipelines.value = false;
    syncPipelineRows();
  }
};

const handlePipelineDragStart = () => {
  draggingPipelines.value = true;
};

const handlePipelineDragEnd = async event => {
  if (event.oldIndex === event.newIndex) {
    draggingPipelines.value = false;
    syncPipelineRows();
    return;
  }

  await persistPipelineOrder();
};

const pipelineStagesById = pipelineId => {
  return (
    referencesStore.pipelines.find(
      pipeline => Number(pipeline.id) === Number(pipelineId)
    )?.stages || []
  );
};

const sortStages = stages => {
  return [...(stages || [])].sort(
    (left, right) => Number(left.position ?? 0) - Number(right.position ?? 0)
  );
};

const defaultStageColor = ({
  currentStageId = stageForm.id,
  pipelineId = stageForm.pipelineId,
} = {}) => {
  return pickStageColor(
    pipelineStagesById(pipelineId),
    STAGE_STANDARD_COLORS,
    currentStageId
  );
};

const unavailableStageStandardColors = computed(
  () =>
    new Set(
      getUnavailableStageColors(
        pipelineStagesById(stageForm.pipelineId),
        STAGE_STANDARD_COLORS,
        stageForm.id
      )
    )
);

const isStageStandardColorDisabled = color => {
  const normalizedColor = String(color || '')
    .trim()
    .toUpperCase();

  if (normalizedColor === normalizedDefaultStageColor) {
    return false;
  }

  return (
    unavailableStageStandardColors.value.has(normalizedColor) &&
    stageForm.color?.toUpperCase() !== normalizedColor
  );
};

const stageStandardColorAriaLabel = color => {
  const suffix = isStageStandardColorDisabled(color)
    ? `, ${t('CRM.SETTINGS.STAGES.FORM.COLOR_UNAVAILABLE')}`
    : '';

  return `${t('CRM.SETTINGS.STAGES.FORM.COLOR')} ${color}${suffix}`;
};

const stageStandardColorTitle = color => {
  if (!isStageStandardColorDisabled(color)) {
    return color;
  }

  return `${color} · ${t('CRM.SETTINGS.STAGES.FORM.COLOR_UNAVAILABLE')}`;
};

const defaultTaskStatusColor = ({
  currentTaskStatusId = taskStatusForm.id,
} = {}) => {
  return pickTaskStatusColor(
    referencesStore.taskStatuses,
    TASK_STATUS_STANDARD_COLORS,
    currentTaskStatusId
  );
};

const unavailableTaskStatusStandardColors = computed(
  () =>
    new Set(
      getUnavailableTaskStatusColors(
        referencesStore.taskStatuses,
        TASK_STATUS_STANDARD_COLORS,
        taskStatusForm.id
      )
    )
);

const isTaskStatusStandardColorDisabled = color => {
  const normalizedColor = String(color || '')
    .trim()
    .toUpperCase();

  if (normalizedColor === normalizedDefaultTaskStatusColor) {
    return false;
  }

  return (
    unavailableTaskStatusStandardColors.value.has(normalizedColor) &&
    taskStatusForm.color?.toUpperCase() !== normalizedColor
  );
};

const taskStatusStandardColorAriaLabel = color => {
  const suffix = isTaskStatusStandardColorDisabled(color)
    ? `, ${t('CRM.SETTINGS.TASK_STATUSES.FORM.COLOR_UNAVAILABLE')}`
    : '';

  return `${t('CRM.SETTINGS.TASK_STATUSES.FORM.COLOR')} ${color}${suffix}`;
};

const taskStatusStandardColorTitle = color => {
  if (!isTaskStatusStandardColorDisabled(color)) {
    return color;
  }

  return `${color} · ${t('CRM.SETTINGS.TASK_STATUSES.FORM.COLOR_UNAVAILABLE')}`;
};

const resetStageForm = () => {
  const firstPipelineId = pipelineOptions.value[0]?.value || '';

  Object.assign(stageForm, {
    active: true,
    code: '',
    color: defaultStageColor({
      currentStageId: null,
      pipelineId: firstPipelineId,
    }),
    id: null,
    name: '',
    outcome: 'open',
    pipelineId: firstPipelineId,
    position: '',
  });
};

const resetTaskStatusForm = () => {
  Object.assign(taskStatusForm, {
    active: true,
    category: 'open',
    color: defaultTaskStatusColor({
      currentTaskStatusId: null,
    }),
    id: null,
    name: '',
  });
};

const openNewPipelineRow = () => {
  if (newPipelineDraft.value) return;

  newPipelineDraft.value = {
    default: false,
    name: '',
  };
};

const cancelNewPipelineRow = () => {
  newPipelineDraft.value = null;
};

const openStageDrawer = ({ pipeline, stage } = {}) => {
  if (stage) {
    Object.assign(stageForm, {
      active: stage.active,
      code: stage.code || '',
      color:
        stage.color ||
        defaultStageColor({
          currentStageId: stage.id,
          pipelineId: stage.pipelineId,
        }),
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
    stageForm.color = defaultStageColor({
      currentStageId: null,
      pipelineId: stageForm.pipelineId,
    });
  }

  stageDrawerOpen.value = true;
};

const openStageOrderDrawer = pipeline => {
  if (!pipeline?.id) return;

  stageOrderPipeline.value = pipeline;
  stageOrderRows.value = sortStages(pipeline.stages);
  stageOrderDrawerOpen.value = true;
};

const closeStageOrderDrawer = (force = false) => {
  if (stageOrderSaving.value && !force) return;

  stageOrderDrawerOpen.value = false;
  stageOrderPipeline.value = null;
  stageOrderRows.value = [];
};

const handleStagePipelineSelection = pipelineId => {
  stageForm.pipelineId = pipelineId;

  if (stageForm.id) return;

  const normalizedColor = String(stageForm.color || '')
    .trim()
    .toUpperCase();
  const nextUnavailableColors = new Set(
    getUnavailableStageColors(
      pipelineStagesById(pipelineId),
      STAGE_STANDARD_COLORS
    )
  );

  if (
    !normalizedColor ||
    (nextUnavailableColors.has(normalizedColor) &&
      normalizedColor !== normalizedDefaultStageColor)
  ) {
    stageForm.color = defaultStageColor({
      currentStageId: null,
      pipelineId,
    });
  }
};

const openTaskStatusDrawer = taskStatus => {
  if (taskStatus) {
    Object.assign(taskStatusForm, {
      active: taskStatus.active,
      category: taskStatus.category || 'open',
      color:
        taskStatus.color ||
        defaultTaskStatusColor({ currentTaskStatusId: taskStatus.id }),
      id: taskStatus.id,
      name: taskStatus.name,
    });
  } else {
    resetTaskStatusForm();
  }

  taskStatusDrawerOpen.value = true;
};

const openDeleteTaskStatusDialog = taskStatus => {
  if (!taskStatus?.id) return;

  taskStatusPendingDelete.value = taskStatus;
  taskStatusDeleteDialogRef.value?.open();
};

const closeDeleteTaskStatusDialog = () => {
  taskStatusPendingDelete.value = null;
};

const deleteTaskStatus = async () => {
  if (!taskStatusPendingDelete.value) return;

  try {
    await referencesStore.deleteTaskStatus(taskStatusPendingDelete.value);
    taskStatusDeleteDialogRef.value?.close();

    if (
      Number(taskStatusForm.id) === Number(taskStatusPendingDelete.value.id)
    ) {
      taskStatusDrawerOpen.value = false;
      resetTaskStatusForm();
    }

    useAlert(t('CRM.SETTINGS.TASK_STATUSES.SUCCESS_DELETE'));
  } catch (error) {
    useAlert(formatErrorMessage(error));
  }
};

const saveNewPipeline = async () => {
  const nextName = String(newPipelineDraft.value?.name || '').trim();
  if (!nextName || pipelineCreateSaving.value) return;

  pipelineCreateSaving.value = true;

  try {
    await referencesStore.savePipeline({
      active: true,
      default: Boolean(newPipelineDraft.value?.default),
      name: nextName,
    });
    useAlert(t('CRM.SETTINGS.PIPELINES.SUCCESS_SAVE'));
    newPipelineDraft.value = null;
  } catch (error) {
    useAlert(formatErrorMessage(error));
  } finally {
    pipelineCreateSaving.value = false;
  }
};

const saveStage = async () => {
  try {
    await referencesStore.saveStage({
      active: stageForm.active,
      color: stageForm.color,
      id: stageForm.id,
      name: stageForm.name.trim(),
      outcome: stageForm.outcome,
      pipelineId: Number(stageForm.pipelineId),
    });
    useAlert(t('CRM.SETTINGS.STAGES.SUCCESS_SAVE'));
    stageDrawerOpen.value = false;
    resetStageForm();
  } catch (error) {
    useAlert(formatErrorMessage(error));
  }
};

const saveStageOrder = async () => {
  if (!stageOrderPipeline.value || stageOrderSaving.value) return;

  stageOrderSaving.value = true;

  try {
    const stageUpdates = stageOrderRows.value
      .map((stage, index) => ({
        ...stage,
        nextPosition: index,
      }))
      .filter(stage => Number(stage.position ?? 0) !== stage.nextPosition);

    await Promise.all(
      stageUpdates.map(stage =>
        referencesStore.saveStage({
          active: stage.active,
          code: stage.code || undefined,
          color:
            stage.color ||
            defaultStageColor({
              currentStageId: stage.id,
              pipelineId: stage.pipelineId || stageOrderPipeline.value.id,
            }),
          id: stage.id,
          name: stage.name,
          outcome: stage.outcome || 'open',
          pipelineId: Number(stage.pipelineId || stageOrderPipeline.value.id),
          position: stage.nextPosition,
        })
      )
    );

    await referencesStore.loadPipelines();
    useAlert(t('CRM.SETTINGS.STAGES.SUCCESS_REORDER'));
    closeStageOrderDrawer(true);
  } catch (error) {
    useAlert(formatErrorMessage(error));
  } finally {
    stageOrderSaving.value = false;
  }
};

const openDeleteStageDialog = stage => {
  const targetStage =
    stage ||
    (stageForm.id
      ? {
          id: stageForm.id,
          name: stageForm.name,
          pipelineId: stageForm.pipelineId,
        }
      : null);

  if (!targetStage) return;

  stagePendingDelete.value = targetStage;
  stageDeleteDialogRef.value?.open();
};

const closeDeleteStageDialog = () => {
  stagePendingDelete.value = null;
};

const deleteStage = async () => {
  if (!stagePendingDelete.value) return;

  try {
    await referencesStore.deleteStage(stagePendingDelete.value);
    stageDeleteDialogRef.value?.close();
    stageDrawerOpen.value = false;
    resetStageForm();
    useAlert(t('CRM.SETTINGS.STAGES.SUCCESS_DELETE'));
  } catch (error) {
    useAlert(formatErrorMessage(error));
  }
};

const saveTaskStatus = async () => {
  try {
    await referencesStore.saveTaskStatus({
      active: taskStatusForm.active,
      category: taskStatusForm.category,
      color: taskStatusForm.color,
      id: taskStatusForm.id,
      name: taskStatusForm.name.trim(),
    });
    useAlert(t('CRM.SETTINGS.TASK_STATUSES.SUCCESS_SAVE'));
    taskStatusDrawerOpen.value = false;
    resetTaskStatusForm();
  } catch (error) {
    useAlert(formatErrorMessage(error));
  }
};

const routeQueryValue = key => {
  const value = route.query[key];
  return Array.isArray(value) ? value[0] : value;
};

const clearRouteActionQuery = async keys => {
  const nextQuery = { ...route.query };
  delete nextQuery.action;
  keys.forEach(key => {
    delete nextQuery[key];
  });

  await router.replace({ query: nextQuery });
};

const consumeRouteAction = async () => {
  if (!canManage.value) {
    return;
  }

  const action = routeQueryValue('action');

  if (action === 'create-stage') {
    const requestedPipelineId = Number(routeQueryValue('pipelineId'));
    const pipeline =
      referencesStore.pipelines.find(
        item => Number(item.id) === requestedPipelineId
      ) || referencesStore.pipelines[0];

    if (pipeline) {
      openStageDrawer({ pipeline });
    }

    await clearRouteActionQuery(['pipelineId']);
    return;
  }

  if (action === 'create-task-status' && tasksEnabled.value) {
    openTaskStatusDrawer();
    await clearRouteActionQuery([]);
  }
};

onMounted(async () => {
  const requests = [];

  if (dealsEnabled.value) {
    requests.push(referencesStore.loadPipelines());
  }

  if (tasksEnabled.value) {
    requests.push(referencesStore.loadTaskStatuses());
  }

  await Promise.all(requests);
  resetStageForm();
  await consumeRouteAction();
});
</script>

<template>
  <SettingsLayout
    :is-loading="
      referencesStore.ui.isLoadingPipelines ||
      referencesStore.ui.isLoadingTaskStatuses
    "
    :loading-message="$t('CRM.SETTINGS.LOADING')"
  >
    <template #header>
      <BaseSettingsHeader :title="$t('CRM.SETTINGS.TITLE')" />
    </template>

    <template #loading>
      <div class="flex justify-center py-16">
        <Spinner class="!h-8 !w-8" />
      </div>
    </template>

    <template #body>
      <div class="grid gap-10">
        <SchedulingErrorState
          v-if="referencesStore.ui.error"
          :title="$t('CRM.ERRORS.LOAD_TITLE')"
          :description="formatErrorMessage(referencesStore.ui.error)"
          @retry="$router.go(0)"
        />

        <SchedulingFormFieldGroup
          v-if="dealsEnabled"
          :framed="false"
          :title="$t('CRM.SETTINGS.PIPELINES.TITLE')"
          :description="$t('CRM.SETTINGS.PIPELINES.DESCRIPTION')"
        >
          <div
            class="mt-3 overflow-hidden rounded-2xl bg-n-solid-2 outline outline-1 outline-n-container shadow-sm"
          >
            <div
              class="grid border-b border-n-weak bg-n-surface-2/80 px-5 py-3 text-[11px] font-semibold uppercase tracking-[0.08em] text-n-slate-10 backdrop-blur"
              :style="{ gridTemplateColumns: pipelineGridTemplate }"
            >
              <div
                v-for="column in pipelineColumns"
                :key="column.key"
                class="min-w-0 truncate"
                :class="[column.align === 'end' ? 'text-end' : 'text-start']"
              >
                {{ column.label }}
              </div>
            </div>

            <div
              v-if="pipelineRows.length === 0 && !newPipelineDraft"
              class="px-5 py-10 text-sm text-center text-n-slate-11"
            >
              {{ $t('SCHEDULING.GENERAL.NO_DATA') }}
            </div>

            <Draggable
              v-if="pipelineRows.length"
              v-model="pipelineRows"
              item-key="id"
              handle=".drag-handle"
              animation="200"
              ghost-class="pipeline-ghost"
              class="divide-y divide-n-weak"
              @start="handlePipelineDragStart"
              @end="handlePipelineDragEnd"
            >
              <template #item="{ element: row }">
                <div
                  class="grid items-center gap-3 px-5 py-3 text-sm text-n-slate-12 transition-colors hover:bg-n-alpha-1"
                  :class="pipelineRowClass(row)"
                  :style="{ gridTemplateColumns: pipelineGridTemplate }"
                >
                  <div class="min-w-0">
                    <div class="flex items-start gap-3">
                      <button
                        type="button"
                        class="drag-handle mt-0.5 inline-flex size-10 shrink-0 items-center justify-center rounded-lg transition-colors"
                        :class="
                          row.active && !pipelineOrderSaving
                            ? 'cursor-grab text-n-slate-10 hover:bg-n-alpha-black2 hover:text-n-slate-12 active:cursor-grabbing'
                            : 'cursor-default text-n-slate-8'
                        "
                        :disabled="!row.active || pipelineOrderSaving"
                        :title="$t('CRM.SETTINGS.PIPELINES.DRAG')"
                      >
                        <span
                          class="i-lucide-grip-vertical size-5"
                          aria-hidden="true"
                        />
                      </button>

                      <div class="min-w-0 flex-1 grid gap-1">
                        <div class="flex flex-wrap items-center gap-2">
                          <Input
                            class="w-full min-w-0 max-w-[11.5rem]"
                            :model-value="
                              pipelineNameDrafts[String(row.id)] ?? row.name
                            "
                            size="sm"
                            :disabled="
                              !row.active ||
                              isPipelineSaving(String(row.id)) ||
                              pipelineOrderSaving
                            "
                            :custom-input-class="pipelineNameInputClass(row)"
                            @update:model-value="
                              pipelineNameDrafts[String(row.id)] = $event
                            "
                            @blur="saveInlinePipelineName(row)"
                            @enter="saveInlinePipelineName(row)"
                          />
                          <span
                            v-if="!row.active"
                            class="inline-flex rounded-full bg-n-slate-3 px-2 py-1 text-[11px] font-medium text-n-slate-10"
                          >
                            {{ $t('CRM.SETTINGS.PIPELINES.ARCHIVED_STATUS') }}
                          </span>
                        </div>
                        <span
                          class="pl-1 text-xs"
                          :class="pipelineSubtextClass(row)"
                        >
                          {{ row.code || '—' }}
                        </span>
                      </div>
                    </div>
                  </div>

                  <div class="min-w-0 pl-3">
                    <div class="flex justify-start">
                      <Switch
                        :model-value="row.default"
                        :disabled="
                          !row.active ||
                          isPipelineSaving(String(row.id)) ||
                          pipelineOrderSaving
                        "
                        @update:model-value="
                          saveInlinePipelineDefault(row, $event)
                        "
                      />
                    </div>
                  </div>

                  <div class="min-w-0">
                    <div class="flex items-center gap-2">
                      <div
                        v-if="canManage && row.active"
                        class="flex shrink-0 items-center gap-1"
                      >
                        <Button
                          size="sm"
                          color="slate"
                          variant="ghost"
                          icon="i-lucide-plus"
                          @click="openStageDrawer({ pipeline: row })"
                        />
                        <Button
                          v-if="row.stages?.length"
                          size="sm"
                          color="slate"
                          variant="ghost"
                          icon="i-lucide-arrow-up-down"
                          :title="$t('CRM.SETTINGS.STAGES.REORDER')"
                          @click="openStageOrderDrawer(row)"
                        />
                      </div>
                      <div
                        class="min-w-0 flex flex-1 flex-wrap items-center gap-2"
                      >
                        <button
                          v-for="stage in row.stages"
                          :key="stage.id"
                          type="button"
                          class="inline-flex items-center gap-2 rounded-full px-2 py-1 text-xs outline outline-1"
                          :disabled="!row.active"
                          :class="
                            row.active
                              ? 'bg-n-alpha-black2 text-n-slate-12 outline-n-weak'
                              : 'bg-n-slate-2 text-n-slate-10 outline-n-container cursor-default pointer-events-none'
                          "
                          @click="openStageDrawer({ stage })"
                        >
                          <span
                            class="size-2 shrink-0 rounded-full outline outline-1 outline-black/10 dark:outline-white/10"
                            :style="{
                              backgroundColor:
                                stage.color || DEFAULT_STAGE_COLOR,
                            }"
                          />
                          {{ stage.name }}
                        </button>
                      </div>
                    </div>
                  </div>

                  <div class="min-w-0 text-end">
                    <div class="flex justify-end gap-1">
                      <Button
                        v-if="canManage"
                        size="sm"
                        :color="row.active ? 'ruby' : 'slate'"
                        variant="ghost"
                        :icon="
                          row.active
                            ? 'i-lucide-archive'
                            : 'i-lucide-rotate-ccw'
                        "
                        @click="toggleInlinePipelineArchived(row, !row.active)"
                      />
                      <Button
                        v-if="canManage && !row.active"
                        size="sm"
                        color="ruby"
                        variant="ghost"
                        icon="i-lucide-trash"
                        :title="$t('CRM.SETTINGS.PIPELINES.DELETE')"
                        @click="openDeletePipelineDialog(row)"
                      />
                    </div>
                  </div>
                </div>
              </template>
            </Draggable>

            <div v-if="newPipelineDraft" class="border-t border-n-weak">
              <div
                class="grid items-center gap-3 px-5 py-3 text-sm text-n-slate-12 bg-n-solid-1"
                :style="{ gridTemplateColumns: pipelineGridTemplate }"
              >
                <div class="min-w-0">
                  <div class="flex items-center gap-3">
                    <span
                      class="inline-flex size-10 shrink-0 items-center justify-center rounded-lg text-n-slate-8"
                      aria-hidden="true"
                    >
                      <span class="i-lucide-plus size-5" />
                    </span>
                    <div class="min-w-0 flex-1 grid gap-1">
                      <Input
                        class="w-full min-w-0 max-w-[11.5rem]"
                        :model-value="newPipelineDraft.name"
                        size="sm"
                        :disabled="pipelineCreateSaving"
                        custom-input-class="font-medium shadow-none !bg-n-solid-1"
                        @update:model-value="newPipelineDraft.name = $event"
                        @enter="saveNewPipeline"
                      />
                    </div>
                  </div>
                </div>

                <div class="min-w-0 pl-3">
                  <div class="flex justify-start">
                    <Switch
                      :model-value="newPipelineDraft.default"
                      :disabled="pipelineCreateSaving"
                      @update:model-value="newPipelineDraft.default = $event"
                    />
                  </div>
                </div>

                <div class="min-w-0 flex items-center">
                  <span class="text-xs leading-5 text-n-slate-10">
                    {{ $t('CRM.SETTINGS.PIPELINES.NEW_PIPELINE_HELP') }}
                  </span>
                </div>

                <div class="min-w-0 flex items-center justify-end">
                  <div class="flex shrink-0 justify-end gap-2">
                    <Button
                      size="sm"
                      color="slate"
                      variant="faded"
                      :disabled="pipelineCreateSaving"
                      :label="$t('SCHEDULING.GENERAL.CANCEL')"
                      @click="cancelNewPipelineRow"
                    />
                    <Button
                      size="sm"
                      :is-loading="pipelineCreateSaving"
                      :disabled="
                        !newPipelineDraft.name.trim() || pipelineCreateSaving
                      "
                      :label="$t('CRM.GENERAL.SAVE')"
                      @click="saveNewPipeline"
                    />
                  </div>
                </div>
              </div>
            </div>
          </div>

          <template #headerActions>
            <div class="flex items-center gap-3">
              <label
                class="flex cursor-pointer items-center gap-2 text-sm text-n-slate-12"
              >
                <Checkbox
                  :model-value="showArchivedPipelines"
                  @update:model-value="showArchivedPipelines = $event"
                />
                <span>{{ $t('CRM.SETTINGS.PIPELINES.SHOW_ARCHIVED') }}</span>
              </label>
              <Button
                v-if="canManage"
                size="sm"
                :disabled="Boolean(newPipelineDraft)"
                icon="i-lucide-plus"
                :label="$t('CRM.SETTINGS.PIPELINES.ADD')"
                @click="openNewPipelineRow()"
              />
            </div>
          </template>
        </SchedulingFormFieldGroup>

        <SchedulingFormFieldGroup
          v-if="tasksEnabled"
          :framed="false"
          :title="$t('CRM.SETTINGS.TASK_STATUSES.TITLE')"
          :description="$t('CRM.SETTINGS.TASK_STATUSES.DESCRIPTION')"
        >
          <div
            class="mt-3 overflow-hidden rounded-2xl bg-n-solid-2 outline outline-1 outline-n-container shadow-sm"
          >
            <div
              class="grid border-b border-n-weak bg-n-surface-2/80 px-5 py-3 text-[11px] font-semibold uppercase tracking-[0.08em] text-n-slate-10 backdrop-blur"
              :style="{ gridTemplateColumns: taskStatusGridTemplate }"
            >
              <div
                v-for="column in taskStatusColumns"
                :key="column.key"
                class="min-w-0 truncate"
                :class="[column.align === 'end' ? 'text-end' : 'text-start']"
              >
                {{ column.label }}
              </div>
            </div>

            <div
              v-if="taskStatusRows.length === 0"
              class="px-5 py-10 text-sm text-center text-n-slate-11"
            >
              {{ $t('SCHEDULING.GENERAL.NO_DATA') }}
            </div>

            <Draggable
              v-else
              v-model="taskStatusRows"
              item-key="id"
              handle=".task-status-drag-handle"
              :disabled="!canManage || taskStatusOrderSaving"
              animation="200"
              ghost-class="pipeline-ghost"
              class="divide-y divide-n-weak"
              @start="handleTaskStatusDragStart"
              @end="handleTaskStatusDragEnd"
            >
              <template #item="{ element: row }">
                <div
                  class="grid items-center gap-3 px-5 py-3 text-sm text-n-slate-12 transition-colors hover:bg-n-alpha-1"
                  :style="{ gridTemplateColumns: taskStatusGridTemplate }"
                >
                  <div class="min-w-0">
                    <div class="flex items-start gap-3">
                      <button
                        type="button"
                        class="task-status-drag-handle mt-0.5 inline-flex size-10 shrink-0 items-center justify-center rounded-lg transition-colors"
                        :class="
                          canManage && !taskStatusOrderSaving
                            ? 'cursor-grab text-n-slate-10 hover:bg-n-alpha-black2 hover:text-n-slate-12 active:cursor-grabbing'
                            : 'cursor-default text-n-slate-8'
                        "
                        :disabled="!canManage || taskStatusOrderSaving"
                        :title="$t('CRM.SETTINGS.TASK_STATUSES.DRAG')"
                      >
                        <span
                          class="i-lucide-grip-vertical size-5"
                          aria-hidden="true"
                        />
                      </button>

                      <div class="min-w-0 flex-1 grid gap-1">
                        <span
                          class="inline-flex min-w-0 items-center gap-2 font-medium text-n-slate-12"
                        >
                          <span
                            class="size-2.5 shrink-0 rounded-full outline outline-1 outline-black/10 dark:outline-white/10"
                            :style="{
                              backgroundColor:
                                row.color || DEFAULT_TASK_STATUS_COLOR,
                            }"
                          />
                          <span class="truncate">{{ row.name }}</span>
                        </span>
                        <span class="pl-1 text-xs text-n-slate-11">
                          {{ row.code || '—' }}
                        </span>
                      </div>
                    </div>
                  </div>

                  <div class="min-w-0">
                    <span class="text-sm text-n-slate-12">
                      {{ taskStatusCategoryLabel(row.category) }}
                    </span>
                  </div>

                  <div class="min-w-0">
                    <div class="flex justify-start">
                      <Switch
                        :model-value="row.default"
                        :disabled="
                          !canManage ||
                          !canToggleTaskStatusDefault(row) ||
                          taskStatusOrderSaving ||
                          referencesStore.ui.isSaving
                        "
                        @update:model-value="
                          saveInlineTaskStatusDefault(row, $event)
                        "
                      />
                    </div>
                  </div>

                  <div class="min-w-0 text-end">
                    <div v-if="canManage" class="flex justify-end gap-1">
                      <Button
                        size="sm"
                        color="slate"
                        variant="ghost"
                        icon="i-lucide-pen-line"
                        @click="openTaskStatusDrawer(row)"
                      />
                      <Button
                        size="sm"
                        color="ruby"
                        variant="ghost"
                        icon="i-lucide-trash"
                        @click="openDeleteTaskStatusDialog(row)"
                      />
                    </div>
                  </div>
                </div>
              </template>
            </Draggable>
          </div>

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
      </div>
    </template>

    <SchedulingDrawer
      v-model="stageOrderDrawerOpen"
      width="md"
      :title="$t('CRM.SETTINGS.STAGES.REORDER_TITLE')"
      :description="
        $t('CRM.SETTINGS.STAGES.REORDER_DESCRIPTION', {
          name: stageOrderPipeline?.name || '',
        })
      "
      :confirm-label="$t('CRM.GENERAL.SAVE')"
      :is-loading="stageOrderSaving"
      :disable-confirm="stageOrderSaving || stageOrderRows.length === 0"
      @close="closeStageOrderDrawer"
      @confirm="saveStageOrder"
    >
      <div class="grid gap-3">
        <div
          v-if="!stageOrderRows.length"
          class="py-10 text-sm text-center text-n-slate-11"
        >
          {{ $t('SCHEDULING.GENERAL.NO_DATA') }}
        </div>

        <Draggable
          v-else
          v-model="stageOrderRows"
          item-key="id"
          handle=".stage-order-drag-handle"
          animation="200"
          ghost-class="pipeline-ghost"
          class="grid gap-2"
        >
          <template #item="{ element: stage, index }">
            <div
              class="flex items-center gap-3 rounded-2xl bg-n-surface-1 px-4 py-3 outline outline-1 outline-n-weak"
            >
              <span
                class="inline-flex size-7 shrink-0 items-center justify-center rounded-full bg-n-alpha-black2 text-xs font-semibold text-n-slate-11"
              >
                {{ index + 1 }}
              </span>
              <span
                class="size-2.5 shrink-0 rounded-full outline outline-1 outline-black/10 dark:outline-white/10"
                :style="{ backgroundColor: stage.color || DEFAULT_STAGE_COLOR }"
              />
              <div class="min-w-0 flex-1">
                <p class="mb-0 truncate text-sm font-medium text-n-slate-12">
                  {{ stage.name }}
                </p>
                <p class="mb-0 truncate text-xs text-n-slate-10">
                  {{ stage.code || '—' }}
                </p>
              </div>
              <button
                type="button"
                class="stage-order-drag-handle inline-flex size-10 shrink-0 items-center justify-center rounded-lg text-n-slate-10 transition-colors hover:bg-n-alpha-black2 hover:text-n-slate-12"
                :title="$t('CRM.SETTINGS.STAGES.REORDER')"
              >
                <span
                  class="i-lucide-grip-vertical size-5"
                  aria-hidden="true"
                />
              </button>
            </div>
          </template>
        </Draggable>
      </div>
    </SchedulingDrawer>

    <SchedulingDrawer
      v-model="stageDrawerOpen"
      width="sm"
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
      <div class="mx-auto grid w-full max-w-[26rem] gap-4">
        <SchedulingSelectField
          :label="$t('CRM.SETTINGS.STAGES.FORM.PIPELINE')"
          :model-value="stageForm.pipelineId"
          :options="pipelineOptions"
          :disabled="Boolean(stageForm.id)"
          @update:model-value="handleStagePipelineSelection($event)"
        />
        <Input
          :label="$t('CRM.SETTINGS.STAGES.FORM.NAME')"
          :model-value="stageForm.name"
          @update:model-value="stageForm.name = $event"
        />
        <div class="grid gap-3">
          <span class="text-sm font-medium text-n-slate-12">
            {{ $t('CRM.SETTINGS.STAGES.FORM.COLOR') }}
          </span>
          <div class="flex flex-wrap gap-2">
            <button
              v-for="color in STAGE_STANDARD_COLORS"
              :key="color"
              type="button"
              class="relative size-8 rounded-full border-2 transition-transform hover:scale-105 disabled:cursor-not-allowed disabled:opacity-100 disabled:hover:scale-100"
              :class="[
                stageForm.color?.toUpperCase() === color.toUpperCase()
                  ? 'ring-2 ring-offset-2 ring-offset-n-surface-1 ring-n-slate-8 border-n-slate-9'
                  : 'border-n-container',
                isStageStandardColorDisabled(color)
                  ? 'border-n-slate-8 shadow-[inset_0_0_0_1px_rgba(15,23,42,0.08)]'
                  : '',
              ]"
              :style="{ backgroundColor: color }"
              :disabled="isStageStandardColorDisabled(color)"
              :aria-label="stageStandardColorAriaLabel(color)"
              :title="stageStandardColorTitle(color)"
              @click="stageForm.color = color"
            >
              <span
                v-if="isStageStandardColorDisabled(color)"
                class="pointer-events-none absolute -bottom-0.5 -right-0.5 flex size-4 items-center justify-center rounded-full bg-n-surface-1 text-n-slate-12 outline outline-1 outline-n-container shadow-sm"
                aria-hidden="true"
              >
                <span class="size-2.5 i-lucide-slash" />
              </span>
            </button>
          </div>
          <div class="grid gap-2 md:max-w-xs">
            <span class="text-sm font-medium text-n-slate-12">
              {{ $t('CRM.SETTINGS.STAGES.FORM.CUSTOM_COLOR') }}
            </span>
            <SchedulingColorPicker v-model="stageForm.color" />
          </div>
        </div>
        <SchedulingSelectField
          :label="$t('CRM.SETTINGS.STAGES.FORM.OUTCOME')"
          :model-value="stageForm.outcome"
          :options="stageOutcomeOptions"
          @update:model-value="stageForm.outcome = $event"
        />
        <div v-if="stageForm.id" class="flex items-center gap-3">
          <Checkbox
            :model-value="!stageForm.active"
            @update:model-value="stageForm.active = !$event"
          />
          <span class="text-sm text-n-slate-12">
            {{ $t('CRM.SETTINGS.STAGES.FORM.DEACTIVATE') }}
          </span>
        </div>
      </div>

      <template #footer>
        <div class="flex items-center justify-between gap-3">
          <Button
            v-if="stageForm.id"
            size="sm"
            color="ruby"
            variant="outline"
            :label="$t('CRM.SETTINGS.STAGES.DELETE')"
            @click="openDeleteStageDialog()"
          />
          <div v-else />
          <div class="flex items-center gap-2">
            <Button
              size="sm"
              variant="faded"
              color="slate"
              :label="$t('SCHEDULING.GENERAL.CANCEL')"
              @click="stageDrawerOpen = false"
            />
            <Button
              size="sm"
              :is-loading="referencesStore.ui.isSaving"
              :disabled="
                !stageForm.name.trim() ||
                !stageForm.pipelineId ||
                referencesStore.ui.isSaving
              "
              :label="$t('CRM.GENERAL.SAVE')"
              @click="saveStage"
            />
          </div>
        </div>
      </template>
    </SchedulingDrawer>

    <Dialog
      ref="pipelineDeleteDialogRef"
      width="md"
      type="alert"
      :title="$t('CRM.SETTINGS.PIPELINES.DELETE_TITLE')"
      :description="
        $t('CRM.SETTINGS.PIPELINES.DELETE_DESCRIPTION', {
          name: pipelinePendingDelete?.name || '',
        })
      "
      :confirm-button-label="$t('CRM.SETTINGS.PIPELINES.DELETE_CONFIRM')"
      :is-loading="referencesStore.ui.isSaving"
      @close="closeDeletePipelineDialog"
      @confirm="deletePipeline"
    />

    <Dialog
      ref="stageDeleteDialogRef"
      width="md"
      type="alert"
      :title="$t('CRM.SETTINGS.STAGES.DELETE_TITLE')"
      :description="
        $t('CRM.SETTINGS.STAGES.DELETE_DESCRIPTION', {
          name: stagePendingDelete?.name || '',
        })
      "
      :confirm-button-label="$t('CRM.SETTINGS.STAGES.DELETE_CONFIRM')"
      :is-loading="referencesStore.ui.isSaving"
      @close="closeDeleteStageDialog"
      @confirm="deleteStage"
    />

    <Dialog
      ref="taskStatusDeleteDialogRef"
      width="md"
      type="alert"
      :title="$t('CRM.SETTINGS.TASK_STATUSES.DELETE_TITLE')"
      :description="
        $t('CRM.SETTINGS.TASK_STATUSES.DELETE_DESCRIPTION', {
          name: taskStatusPendingDelete?.name || '',
        })
      "
      :confirm-button-label="$t('CRM.SETTINGS.TASK_STATUSES.DELETE_CONFIRM')"
      :is-loading="referencesStore.ui.isSaving"
      @close="closeDeleteTaskStatusDialog"
      @confirm="deleteTaskStatus"
    />

    <SchedulingDrawer
      v-model="taskStatusDrawerOpen"
      width="sm"
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
      <div class="mx-auto grid w-full max-w-[26rem] gap-4">
        <Input
          :label="$t('CRM.SETTINGS.TASK_STATUSES.FORM.NAME')"
          :model-value="taskStatusForm.name"
          @update:model-value="taskStatusForm.name = $event"
        />
        <div class="grid gap-3">
          <span class="text-sm font-medium text-n-slate-12">
            {{ $t('CRM.SETTINGS.TASK_STATUSES.FORM.COLOR') }}
          </span>
          <div class="flex flex-wrap gap-2">
            <button
              v-for="color in TASK_STATUS_STANDARD_COLORS"
              :key="color"
              type="button"
              class="relative size-8 rounded-full border-2 transition-transform hover:scale-105 disabled:cursor-not-allowed disabled:opacity-100 disabled:hover:scale-100"
              :class="[
                taskStatusForm.color?.toUpperCase() === color.toUpperCase()
                  ? 'ring-2 ring-offset-2 ring-offset-n-surface-1 ring-n-slate-8 border-n-slate-9'
                  : 'border-n-container',
                isTaskStatusStandardColorDisabled(color)
                  ? 'border-n-slate-8 shadow-[inset_0_0_0_1px_rgba(15,23,42,0.08)]'
                  : '',
              ]"
              :style="{ backgroundColor: color }"
              :disabled="isTaskStatusStandardColorDisabled(color)"
              :aria-label="taskStatusStandardColorAriaLabel(color)"
              :title="taskStatusStandardColorTitle(color)"
              @click="taskStatusForm.color = color"
            >
              <span
                v-if="isTaskStatusStandardColorDisabled(color)"
                class="pointer-events-none absolute -bottom-0.5 -right-0.5 flex size-4 items-center justify-center rounded-full bg-n-surface-1 text-n-slate-12 outline outline-1 outline-n-container shadow-sm"
                aria-hidden="true"
              >
                <span class="size-2.5 i-lucide-slash" />
              </span>
            </button>
          </div>
          <div class="grid gap-2 md:max-w-xs">
            <span class="text-sm font-medium text-n-slate-12">
              {{ $t('CRM.SETTINGS.TASK_STATUSES.FORM.CUSTOM_COLOR') }}
            </span>
            <SchedulingColorPicker v-model="taskStatusForm.color" />
          </div>
        </div>
        <SchedulingSelectField
          :label="$t('CRM.SETTINGS.TASK_STATUSES.FORM.CATEGORY')"
          :model-value="taskStatusForm.category"
          :options="taskStatusCategoryOptions"
          @update:model-value="taskStatusForm.category = $event"
        />
        <div v-if="taskStatusForm.id" class="flex items-center gap-3">
          <Checkbox
            :model-value="!taskStatusForm.active"
            @update:model-value="taskStatusForm.active = !$event"
          />
          <span class="text-sm text-n-slate-12">
            {{ $t('CRM.SETTINGS.TASK_STATUSES.FORM.DEACTIVATE') }}
          </span>
        </div>
      </div>
    </SchedulingDrawer>
  </SettingsLayout>
</template>

<style scoped lang="scss">
.pipeline-ghost {
  @apply opacity-50 bg-n-slate-3 dark:bg-n-slate-9;
}
</style>
