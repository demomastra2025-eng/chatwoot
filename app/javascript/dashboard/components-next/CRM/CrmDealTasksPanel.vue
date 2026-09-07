<script setup>
import {
  computed,
  onBeforeUnmount,
  onMounted,
  reactive,
  ref,
  watch,
} from 'vue';
import { format } from 'date-fns';
import { useI18n } from 'vue-i18n';

import CrmTasksAPI from 'dashboard/api/crm/tasks';
import CrmDealsAPI from 'dashboard/api/crm/deals';
import { useAlert } from 'dashboard/composables';
import Button from 'dashboard/components-next/button/Button.vue';
import Dialog from 'dashboard/components-next/dialog/Dialog.vue';
import Icon from 'dashboard/components-next/icon/Icon.vue';
import Input from 'dashboard/components-next/input/Input.vue';
import TextArea from 'dashboard/components-next/textarea/TextArea.vue';
import CrmCustomFieldsSection from 'dashboard/components-next/CRM/CrmCustomFieldsSection.vue';
import CrmTaskCompletionDialog from 'dashboard/components-next/CRM/CrmTaskCompletionDialog.vue';
import SchedulingDateTimeField from 'dashboard/components-next/Scheduling/SchedulingDateTimeField.vue';
import SchedulingSelectField from 'dashboard/components-next/Scheduling/SchedulingSelectField.vue';
import {
  assertTaskEditCurrent,
  buildTaskFormSavePayload,
  cloneTaskDraft,
  rememberTaskSnapshot,
} from 'dashboard/routes/dashboard/crm/taskLifecyclePayload';
import { taskDueDate } from 'dashboard/routes/dashboard/crm/taskTimeBuckets';
import {
  buildDefaultCustomAttributes,
  reconcileCustomAttributesForDefinitions,
} from 'dashboard/stores/crm/customFieldDefaults';
import {
  compactPayload,
  formatCrmErrorMessage,
  normalizePayload,
} from 'dashboard/stores/crm/shared';
import { BUS_EVENTS } from 'shared/constants/busEvents';
import { emitter } from 'shared/helpers/mitt';

const props = defineProps({
  assignees: {
    type: Array,
    default: () => [],
  },
  canManageTasks: {
    type: Boolean,
    default: false,
  },
  canManageDeals: {
    type: Boolean,
    default: false,
  },
  createActionIconOnly: {
    type: Boolean,
    default: false,
  },
  deal: {
    type: Object,
    default: null,
  },
  statuses: {
    type: Array,
    default: () => [],
  },
  showCreateActions: {
    type: Boolean,
    default: true,
  },
  taskFieldDefinitions: {
    type: Array,
    default: () => [],
  },
  taskTypes: {
    type: Array,
    default: () => [],
  },
});

const emit = defineEmits(['created', 'dealUpdated', 'updated']);
const { t } = useI18n();

const taskDialogRef = ref(null);
const resultDialogRef = ref(null);
const waitingDialogRef = ref(null);
const selectedTask = ref(null);
const taskEditSnapshot = ref(null);
const tasks = ref([]);
const ui = reactive({
  isLoading: false,
  isSaving: false,
});
const form = reactive({
  activityType: 'task',
  assigneeId: '',
  contextKind: 'sales',
  customAttributes: {},
  description: '',
  dueAt: '',
  outcome: '',
  outcomeNote: '',
  priority: 'medium',
  startAt: '',
  statusId: '',
  teamId: '',
  title: '',
});
const waitingForm = reactive({
  createWakeUpTask: true,
  reason: '',
  until: '',
});
const TASK_ACTIVITY_TYPES = ['task', 'call', 'meeting', 'message', 'touch'];
const NOT_DONE_OUTCOME = 'not_done';

const activityTypeMetaByValue = computed(() => ({
  call: {
    icon: 'i-lucide-phone',
    label: t('CRM.TASKS.ACTIVITY_TYPE.call'),
  },
  meeting: {
    icon: 'i-lucide-users',
    label: t('CRM.TASKS.ACTIVITY_TYPE.meeting'),
  },
  message: {
    icon: 'i-lucide-message-square',
    label: t('CRM.TASKS.ACTIVITY_TYPE.message'),
  },
  task: {
    icon: 'i-lucide-list-todo',
    label: t('CRM.TASKS.ACTIVITY_TYPE.task'),
  },
  touch: {
    icon: 'i-lucide-handshake',
    label: t('CRM.TASKS.ACTIVITY_TYPE.touch'),
  },
}));

const activityTypeOptions = computed(() =>
  (props.taskTypes.filter(taskType => taskType.active !== false).length
    ? props.taskTypes.filter(taskType => taskType.active !== false)
    : TASK_ACTIVITY_TYPES.map(value => ({ code: value }))
  ).map(taskType => ({
    icon: taskType.icon || activityTypeMetaByValue.value[taskType.code]?.icon,
    label:
      taskType.name ||
      activityTypeMetaByValue.value[taskType.code]?.label ||
      taskType.code,
    value: taskType.code,
  }))
);

const outcomeLabelByValue = computed(() => ({
  answered: t('CRM.TASKS.OUTCOME.answered'),
  busy: t('CRM.TASKS.OUTCOME.busy'),
  cancelled: t('CRM.TASKS.OUTCOME.cancelled'),
  completed: t('CRM.TASKS.OUTCOME.completed'),
  failed: t('CRM.TASKS.OUTCOME.failed'),
  held: t('CRM.TASKS.OUTCOME.held'),
  no_answer: t('CRM.TASKS.OUTCOME.no_answer'),
  no_show: t('CRM.TASKS.OUTCOME.no_show'),
  not_done: t('CRM.TASKS.OUTCOME.not_done'),
  other: t('CRM.TASKS.OUTCOME.other'),
  rescheduled: t('CRM.TASKS.OUTCOME.rescheduled'),
  sent: t('CRM.TASKS.OUTCOME.sent'),
}));

const taskTypeByCode = computed(() =>
  props.taskTypes.reduce((result, taskType) => {
    result[taskType.code] = taskType;
    return result;
  }, {})
);

const activityTypeLabel = task =>
  task.taskType?.name ||
  taskTypeByCode.value[task.activityType]?.name ||
  activityTypeMetaByValue.value[task.activityType || 'task']?.label ||
  task.activityType;

const activityTypeIcon = task =>
  task.taskType?.icon ||
  taskTypeByCode.value[task.activityType]?.icon ||
  activityTypeMetaByValue.value[task.activityType || 'task']?.icon ||
  'i-lucide-list-todo';

const updateFormActivityType = value => {
  const available = activityTypeOptions.value.some(
    option => option.value === value
  );
  form.activityType = available
    ? value
    : activityTypeOptions.value[0]?.value || 'task';
  form.outcome = '';
  form.outcomeNote = '';
};

const defaultStatus = computed(
  () =>
    props.statuses.find(status => status.default) ||
    props.statuses.find(status => status.category === 'open') ||
    props.statuses[0]
);

const doneStatus = computed(() =>
  props.statuses.find(status => status.category === 'done')
);

const taskFieldDefinitionsForContext = contextKind =>
  props.taskFieldDefinitions.filter(definition => {
    const contexts = definition.rules?.contexts || [];
    const context = contextKind === 'sales' ? 'deal_task' : 'standalone_task';
    return contexts.length === 0 || contexts.includes(context);
  });

const applicableTaskFieldDefinitions = computed(() =>
  taskFieldDefinitionsForContext(form.contextKind)
);

const taskCustomAttributesForContext = (customAttributes, contextKind) => {
  const draft = cloneTaskDraft(customAttributes || {});
  if (!props.taskFieldDefinitions.length) return draft;

  return reconcileCustomAttributesForDefinitions(
    draft,
    taskFieldDefinitionsForContext(contextKind)
  );
};

const taskStatusById = computed(() =>
  props.statuses.reduce((result, status) => {
    result[Number(status.id)] = status;
    return result;
  }, {})
);

const taskStatusCategory = task =>
  taskStatusById.value[Number(task.statusId)]?.category || 'open';

const taskResultValue = task => {
  if (taskStatusCategory(task) !== 'done') return '';
  return task.outcome || 'completed';
};

const taskResultButtonClass = task => {
  const value = taskResultValue(task);

  if (!value) {
    return 'border-n-weak bg-n-alpha-black2 text-n-slate-11 hover:border-n-slate-6 hover:text-n-slate-12';
  }

  return value === NOT_DONE_OUTCOME
    ? 'border-n-ruby-6 bg-n-ruby-3 text-n-ruby-11 hover:border-n-ruby-7 hover:bg-n-ruby-4'
    : 'border-n-weak bg-n-alpha-black2 text-n-slate-11 hover:border-n-slate-6 hover:text-n-slate-12';
};

const taskResultActionLabel = task => {
  const value = taskResultValue(task);
  if (!value) return t('CRM.TASKS.RESULT_DIALOG.ACTION');

  return (
    outcomeLabelByValue.value[value] ||
    t('CRM.TASKS.RESULT_DIALOG.CHANGE_ACTION')
  );
};

const taskResultActionIcon = task => {
  const value = taskResultValue(task);
  if (value === NOT_DONE_OUTCOME) return 'i-lucide-circle-x';
  return value ? 'i-lucide-circle-check' : 'i-lucide-check';
};

const taskOutcomeNote = task => task.outcomeNote || '';

const taskResultNotePrefix = task =>
  outcomeLabelByValue.value[taskResultValue(task)] ||
  t('CRM.TASKS.RESULT_DIALOG.CHANGE_ACTION');

const taskResultNoteLabel = task => `${taskResultNotePrefix(task)}:`;

const canEditTask = task =>
  props.canManageTasks &&
  !task.archivedAt &&
  taskStatusCategory(task) !== 'done';
const canOpenTaskDialog = task =>
  canEditTask(task) ||
  (!task.archivedAt && taskStatusCategory(task) === 'done');

const canSetTaskResult = task =>
  props.canManageTasks && !task.archivedAt && Boolean(doneStatus.value);

const sortedTasks = computed(() =>
  [...tasks.value].sort((left, right) => {
    const leftDone = taskStatusCategory(left) === 'done' ? 1 : 0;
    const rightDone = taskStatusCategory(right) === 'done' ? 1 : 0;

    if (leftDone !== rightDone) return leftDone - rightDone;

    const leftDate =
      taskDueDate(left) || new Date(left.updatedAt || left.createdAt || 0);
    const rightDate =
      taskDueDate(right) || new Date(right.updatedAt || right.createdAt || 0);

    return leftDate - rightDate;
  })
);

const hasDeal = computed(() => !!props.deal?.id);
const canCreateTask = computed(() => props.canManageTasks && hasDeal.value);
const isDealWaiting = computed(() =>
  ['waiting', 'waitingExpired'].includes(props.deal?.nextAction?.kind)
);
const waitingKind = computed(() => props.deal?.nextAction?.kind || 'none');
const shouldShowCreateActions = computed(
  () => props.showCreateActions && props.canManageTasks
);
const shouldShowWaitingAction = computed(
  () => props.showCreateActions && props.canManageDeals
);
const isEditingTask = computed(() => !!selectedTask.value);
const isTaskReadOnly = computed(
  () => !!selectedTask.value && !canEditTask(selectedTask.value)
);
const isTaskFormDisabled = computed(
  () =>
    isTaskReadOnly.value ||
    !form.title.trim() ||
    !form.statusId ||
    !hasDeal.value ||
    (form.outcome === NOT_DONE_OUTCOME && !form.outcomeNote.trim())
);

const taskDialogTitle = computed(() => {
  if (isTaskReadOnly.value) return t('CRM.TASKS.VIEW_TITLE');
  if (isEditingTask.value) return t('CRM.TASKS.EDIT_TITLE');
  return t('CRM.TASKS.CREATE_TITLE');
});
const taskDialogDescription = computed(() => {
  if (isTaskReadOnly.value) return t('CRM.TASKS.VIEW_DESCRIPTION');
  if (isEditingTask.value) return t('CRM.DEALS.TASKS.EDIT_DESCRIPTION');
  return t('CRM.DEALS.TASKS.CREATE_DESCRIPTION');
});
const taskDialogConfirmLabel = computed(() =>
  isEditingTask.value ? t('CRM.GENERAL.SAVE') : t('CRM.GENERAL.CREATE')
);
const taskDialogCancelLabel = computed(() =>
  isTaskReadOnly.value ? t('CRM.GENERAL.CLOSE') : t('CRM.GENERAL.CANCEL')
);

const buildCreateTaskTitle = () =>
  t('CRM.TASKS.PREFILL.DEAL', {
    dealTitle: props.deal?.title || `#${props.deal?.id}`,
  });

const resetForm = () => {
  Object.assign(form, {
    activityType: 'task',
    assigneeId: props.deal?.ownerId || '',
    contextKind: 'sales',
    customAttributes: buildDefaultCustomAttributes(
      taskFieldDefinitionsForContext('sales')
    ),
    description: '',
    dueAt: '',
    outcome: '',
    outcomeNote: '',
    priority: 'medium',
    startAt: '',
    statusId: defaultStatus.value?.id || '',
    teamId: props.deal?.teamId || '',
    title: buildCreateTaskTitle(),
  });
};

const taskLoadGeneration = ref(0);
let taskRealtimeSequence = 0;
const pendingTaskRealtimeUpdates = new Map();

const upsertTask = task => {
  if (rememberTaskSnapshot(pendingTaskRealtimeUpdates, task) !== task) return;
  const index = tasks.value.findIndex(
    item => Number(item.id) === Number(task.id)
  );
  const nextTasks = [...tasks.value];

  if (index === -1) {
    nextTasks.unshift(task);
  } else {
    nextTasks.splice(index, 1, task);
  }

  tasks.value = nextTasks;
};

const applyTaskRealtimeUpdate = task => {
  if (rememberTaskSnapshot(pendingTaskRealtimeUpdates, task) !== task) return;
  if (Number(selectedTask.value?.id) === Number(task.id))
    selectedTask.value = task;
  if (Number(task.dealId) !== Number(props.deal?.id)) {
    tasks.value = tasks.value.filter(
      item => Number(item.id) !== Number(task.id)
    );
    return;
  }

  if (task.archivedAt || task.cancelledAt) {
    tasks.value = tasks.value.filter(
      item => Number(item.id) !== Number(task.id)
    );
  } else {
    upsertTask(task);
  }

  if (Number(selectedTask.value?.id) === Number(task.id)) {
    selectedTask.value = task;
  }
};

const runTaskMutation = async (request, expectedTask) => {
  const dealAtStart = props.deal?.id;
  if (expectedTask) {
    assertTaskEditCurrent(
      expectedTask,
      pendingTaskRealtimeUpdates.get(Number(expectedTask.id))?.task ||
        expectedTask
    );
  }
  const response = await request();
  if (dealAtStart !== props.deal?.id) assertTaskEditCurrent(null, null);
  const responseTask = normalizePayload(response.data);
  taskRealtimeSequence += 1;
  const newest = rememberTaskSnapshot(
    pendingTaskRealtimeUpdates,
    responseTask,
    taskRealtimeSequence
  );
  applyTaskRealtimeUpdate(newest);
  if (expectedTask) assertTaskEditCurrent(responseTask, newest);
  return newest;
};

const handleCrmTaskRealtimeEvent = payload => {
  if (!payload?.task) return;

  taskRealtimeSequence += 1;
  const task = rememberTaskSnapshot(
    pendingTaskRealtimeUpdates,
    normalizePayload({ payload: payload.task }),
    taskRealtimeSequence
  );
  applyTaskRealtimeUpdate(task);
};

onMounted(() => {
  emitter.on(BUS_EVENTS.CRM_TASK_REALTIME_EVENT, handleCrmTaskRealtimeEvent);
});

onBeforeUnmount(() => {
  emitter.off(BUS_EVENTS.CRM_TASK_REALTIME_EVENT, handleCrmTaskRealtimeEvent);
  taskLoadGeneration.value += 1;
  pendingTaskRealtimeUpdates.clear();
});

const loadTasks = async () => {
  if (!hasDeal.value) {
    tasks.value = [];
    return;
  }

  taskLoadGeneration.value += 1;
  const loadGeneration = taskLoadGeneration.value;
  const realtimeSequenceAtStart = taskRealtimeSequence;
  ui.isLoading = true;

  try {
    const { data } = await CrmTasksAPI.get({
      archived: false,
      deal_id: props.deal.id,
    });
    if (loadGeneration !== taskLoadGeneration.value) return;

    tasks.value = normalizePayload(data)
      .map(task => rememberTaskSnapshot(pendingTaskRealtimeUpdates, task))
      .filter(
        task =>
          Number(task.dealId) === Number(props.deal?.id) &&
          !task.archivedAt &&
          !task.cancelledAt
      );
    pendingTaskRealtimeUpdates.forEach(update => {
      if (update.sequence <= realtimeSequenceAtStart) return;

      applyTaskRealtimeUpdate(update.task);
    });
  } catch (error) {
    if (loadGeneration !== taskLoadGeneration.value) return;
    useAlert(formatCrmErrorMessage(error, t));
  } finally {
    if (loadGeneration === taskLoadGeneration.value) ui.isLoading = false;
  }
};

const buildPayload = () => {
  const taskType = props.taskTypes.find(
    candidate => candidate.code === form.activityType
  );
  const payload = compactPayload({
    activity_type: form.activityType || 'task',
    task_type_id: taskType?.id ? Number(taskType.id) : undefined,
    assignee_id: form.assigneeId ? Number(form.assigneeId) : undefined,
    context_kind: form.contextKind,
    custom_attributes: form.customAttributes,
    deal_id: Number(props.deal.id),
    description: form.description || undefined,
    due_at: form.dueAt || undefined,
    lock_version: selectedTask.value?.lockVersion,
    outcome: form.outcome || undefined,
    outcome_note: form.outcomeNote || undefined,
    priority: form.priority || undefined,
    start_at: form.startAt || undefined,
    status_id: form.statusId ? Number(form.statusId) : undefined,
    team_id: form.teamId ? Number(form.teamId) : undefined,
    title: form.title.trim(),
  });

  if (selectedTask.value) {
    payload.description = form.description || null;
    if (!form.outcome) payload.outcome = '';
    if (!form.outcomeNote) payload.outcome_note = '';
  }

  return payload;
};

const openCreateTaskDialog = () => {
  if (!canCreateTask.value) return;

  selectedTask.value = null;
  taskEditSnapshot.value = null;
  resetForm();
  taskDialogRef.value?.open();
};

const openWaitingDialog = () => {
  if (!props.canManageDeals || !hasDeal.value) return;

  Object.assign(waitingForm, {
    createWakeUpTask: !isDealWaiting.value,
    reason: props.deal?.waitingReason || '',
    until: props.deal?.waitingUntil?.slice(0, 16) || '',
  });
  waitingDialogRef.value?.open();
};

const saveWaiting = async () => {
  if (!waitingForm.until || !waitingForm.reason.trim()) return;

  ui.isSaving = true;
  try {
    const response = await CrmDealsAPI.setWaiting(props.deal.id, {
      create_wake_up_task: props.canManageTasks && waitingForm.createWakeUpTask,
      lock_version: props.deal.lockVersion,
      waiting_reason: waitingForm.reason.trim(),
      waiting_until: new Date(waitingForm.until).toISOString(),
      wake_up_task_title:
        props.canManageTasks && waitingForm.createWakeUpTask
          ? t('CRM.DEALS.WAITING.WAKE_UP_TASK', { title: props.deal.title })
          : undefined,
    });
    emit('dealUpdated', normalizePayload(response.data));
    waitingDialogRef.value?.close();
    await loadTasks();
    useAlert(t('CRM.DEALS.WAITING.SAVED'));
  } catch (error) {
    useAlert(formatCrmErrorMessage(error, t));
  } finally {
    ui.isSaving = false;
  }
};

const clearWaiting = async () => {
  if (!isDealWaiting.value) return;

  ui.isSaving = true;
  try {
    const response = await CrmDealsAPI.clearWaiting(props.deal.id, {
      lock_version: props.deal.lockVersion,
    });
    emit('dealUpdated', normalizePayload(response.data));
    useAlert(t('CRM.DEALS.WAITING.CLEARED'));
  } catch (error) {
    useAlert(formatCrmErrorMessage(error, t));
  } finally {
    ui.isSaving = false;
  }
};

const fillFormFromTask = task => {
  const contextKind = task.contextKind || (task.dealId ? 'sales' : 'personal');
  Object.assign(form, {
    activityType: task.activityType || 'task',
    assigneeId: task.assigneeId ?? '',
    contextKind,
    customAttributes: taskCustomAttributesForContext(
      task.customAttributes,
      contextKind
    ),
    description: task.description || '',
    dueAt: task.dueAt ? task.dueAt.slice(0, 16) : '',
    outcome: task.outcome || '',
    outcomeNote: task.outcomeNote || '',
    priority: task.priority || 'medium',
    startAt: task.startAt ? task.startAt.slice(0, 16) : '',
    statusId: task.statusId || defaultStatus.value?.id || '',
    teamId: task.teamId ?? '',
    title: task.title || '',
  });
};

const openTaskDialog = task => {
  if (!canOpenTaskDialog(task)) return;

  selectedTask.value = task;
  fillFormFromTask(task);
  taskEditSnapshot.value = cloneTaskDraft({ task, payload: buildPayload() });
  taskDialogRef.value?.open();
};

const closeTaskDialog = () => {
  taskDialogRef.value?.close();
  selectedTask.value = null;
  taskEditSnapshot.value = null;
  resetForm();
};

const saveTask = async () => {
  if (isTaskReadOnly.value || isTaskFormDisabled.value || ui.isSaving) return;

  ui.isSaving = true;

  try {
    const payload = buildPayload();
    const draft = cloneTaskDraft(form);
    const wasEditing = !!selectedTask.value;
    let task;

    if (wasEditing) {
      const currentTask = taskEditSnapshot.value?.task;
      const savePayload = buildTaskFormSavePayload({
        snapshot: taskEditSnapshot.value,
        currentTask: selectedTask.value,
        requested: payload,
        form: { ...draft, allDay: false },
        includeStatus: true,
        preserveAllDay: true,
      });
      task = await runTaskMutation(() =>
        CrmTasksAPI.saveForm(currentTask.id, savePayload)
      );
    } else {
      task = await runTaskMutation(() => CrmTasksAPI.create(payload));
      emit('created', task);
    }

    applyTaskRealtimeUpdate(task);
    if (wasEditing) {
      emit('updated', task);
    }
    useAlert(
      wasEditing
        ? t('CRM.TASKS.SUCCESS_UPDATED')
        : t('CRM.TASKS.SUCCESS_CREATED')
    );
    closeTaskDialog();
  } catch (error) {
    useAlert(formatCrmErrorMessage(error, t));
  } finally {
    ui.isSaving = false;
  }
};

const openTaskResultDialog = task => {
  if (!canSetTaskResult(task)) return;

  resultDialogRef.value?.open(task);
};

const closeTaskResultDialog = () => {
  resultDialogRef.value?.close();
};

const saveTaskResult = async ({ task, note, taskOutcomeId }) => {
  const currentTask =
    tasks.value.find(item => Number(item.id) === Number(task.id)) || task;

  ui.isSaving = true;

  try {
    const updatedTask = await runTaskMutation(() =>
      CrmTasksAPI.complete(currentTask.id, {
        idempotency_key: crypto.randomUUID(),
        lock_version: currentTask.lockVersion,
        outcome_note: note,
        task_outcome_id: Number(taskOutcomeId),
      })
    );

    applyTaskRealtimeUpdate(updatedTask);
    emit('updated', updatedTask);
    useAlert(t('CRM.TASKS.SUCCESS_UPDATED'));
    closeTaskResultDialog();
  } catch (error) {
    useAlert(formatCrmErrorMessage(error, t));
  } finally {
    ui.isSaving = false;
  }
};

const formatDate = value => {
  if (!value) return '';
  return format(new Date(value), 'MMM d, yyyy HH:mm');
};

const taskDateSummary = task => {
  const dueDate = taskDueDate(task);
  if (dueDate) {
    return t('CRM.DEALS.TASKS.DUE_AT', { date: formatDate(dueDate) });
  }

  if (task.startAt) {
    return t('CRM.DEALS.TASKS.START_AT', { date: formatDate(task.startAt) });
  }

  return '';
};

watch(
  () => props.deal?.id,
  () => {
    taskLoadGeneration.value += 1;
    pendingTaskRealtimeUpdates.clear();
    taskRealtimeSequence = 0;
    tasks.value = [];
    closeTaskDialog();
    loadTasks();
  },
  { immediate: true }
);

watch(applicableTaskFieldDefinitions, definitions => {
  if (!definitions.length) return;

  form.customAttributes = reconcileCustomAttributesForDefinitions(
    form.customAttributes,
    definitions
  );
});

defineExpose({ openCreateTaskDialog, loadTasks });
</script>

<template>
  <section
    class="overflow-hidden rounded-2xl border border-n-weak bg-n-solid-1 shadow-sm"
  >
    <header
      class="flex items-center justify-between gap-3 border-b border-n-weak px-4 py-3"
    >
      <div class="flex min-w-0 items-center gap-2">
        <Icon icon="i-lucide-list-checks" class="size-4 text-n-slate-10" />
        <p class="mb-0 truncate text-sm font-medium text-n-slate-12">
          {{ $t('CRM.DEALS.TASKS.COUNT', { count: tasks.length }) }}
        </p>
      </div>

      <div
        v-if="shouldShowWaitingAction || shouldShowCreateActions"
        class="flex items-center gap-1"
      >
        <Button
          v-if="shouldShowWaitingAction"
          size="sm"
          color="slate"
          variant="ghost"
          :icon="isDealWaiting ? 'i-lucide-play' : 'i-lucide-pause'"
          :label="
            createActionIconOnly
              ? ''
              : isDealWaiting
                ? $t('CRM.DEALS.WAITING.CLEAR_ACTION')
                : $t('CRM.DEALS.WAITING.SET_ACTION')
          "
          :disabled="!hasDeal || ui.isSaving"
          @click="isDealWaiting ? clearWaiting() : openWaitingDialog()"
        />
        <Button
          v-tooltip.top="
            createActionIconOnly ? $t('CRM.DEALS.TASKS.ADD') : undefined
          "
          size="sm"
          color="slate"
          variant="ghost"
          icon="i-lucide-plus"
          :label="createActionIconOnly ? '' : $t('CRM.DEALS.TASKS.ADD')"
          :disabled="!hasDeal"
          @click="openCreateTaskDialog"
        />
      </div>
    </header>

    <div
      v-if="isDealWaiting"
      class="flex items-start gap-2 border-b border-n-weak px-4 py-3"
      :class="
        waitingKind === 'waitingExpired'
          ? 'bg-n-ruby-3 text-n-ruby-11'
          : 'bg-n-amber-3 text-n-amber-11'
      "
    >
      <Icon icon="i-lucide-clock-3" class="mt-0.5 size-4 shrink-0" />
      <div class="min-w-0">
        <p class="mb-0 text-xs font-medium">
          {{
            waitingKind === 'waitingExpired'
              ? $t('CRM.DEALS.WAITING.EXPIRED', {
                  date: formatDate(deal.waitingUntil),
                })
              : $t('CRM.DEALS.WAITING.ACTIVE', {
                  date: formatDate(deal.waitingUntil),
                })
          }}
        </p>
        <p class="mb-0 truncate text-[11px]">{{ deal.waitingReason }}</p>
      </div>
    </div>

    <div
      v-if="ui.isLoading"
      class="px-4 py-6 text-center text-sm text-n-slate-11"
    >
      {{ $t('CRM.DEALS.TASKS.LOADING') }}
    </div>

    <div
      v-else-if="sortedTasks.length === 0"
      class="grid place-items-center gap-3 px-4 py-8 text-center"
    >
      <span
        class="flex size-10 items-center justify-center rounded-2xl bg-n-alpha-black2 text-n-slate-11"
      >
        <Icon icon="i-lucide-list-checks" class="size-5" />
      </span>
      <div class="grid gap-1">
        <p class="mb-0 text-sm font-medium text-n-slate-12">
          {{ $t('CRM.DEALS.TASKS.EMPTY_TITLE') }}
        </p>
        <p class="mb-0 text-sm text-n-slate-11">
          {{ $t('CRM.DEALS.TASKS.EMPTY_DESCRIPTION') }}
        </p>
      </div>
    </div>

    <ol v-else class="divide-y divide-n-weak">
      <li
        v-for="task in sortedTasks"
        :key="task.id"
        class="group grid gap-1.5 px-3 py-2 transition-colors hover:bg-n-alpha-black2/70"
      >
        <div class="flex min-w-0 items-start justify-between gap-2">
          <div class="grid min-w-0 gap-0.5">
            <div class="flex min-w-0 items-center gap-1">
              <button
                type="button"
                class="min-w-0 text-left disabled:cursor-default"
                :disabled="!canOpenTaskDialog(task)"
                :aria-label="
                  canEditTask(task)
                    ? $t('CRM.TASKS.EDIT_TITLE')
                    : $t('CRM.TASKS.VIEW_TITLE')
                "
                @click="openTaskDialog(task)"
              >
                <span
                  class="block truncate text-xs font-medium leading-4 text-n-slate-12 transition-colors"
                  :class="canOpenTaskDialog(task) ? 'hover:text-n-brand' : ''"
                >
                  {{ task.title }}
                </span>
              </button>
            </div>
            <div class="flex flex-wrap items-center gap-1">
              <span
                class="inline-flex items-center gap-1 rounded-full border border-n-weak bg-n-surface-1 px-1.5 py-0.5 text-[10px] font-medium text-n-slate-11"
              >
                <span
                  class="size-3"
                  :class="activityTypeIcon(task)"
                  aria-hidden="true"
                />
                {{ activityTypeLabel(task) }}
              </span>
              <span
                v-if="task.archivedAt"
                class="rounded-full bg-n-amber-3 px-1.5 py-0.5 text-[10px] font-medium text-n-amber-11"
              >
                {{ $t('CRM.GENERAL.ARCHIVED') }}
              </span>
            </div>
            <p
              v-if="task.description"
              class="mb-0 line-clamp-1 whitespace-pre-wrap text-[11px] leading-3 text-n-slate-11"
            >
              {{ task.description }}
            </p>
            <p
              v-if="taskDateSummary(task)"
              class="mb-0 text-[11px] leading-3 text-n-slate-10"
            >
              {{ taskDateSummary(task) }}
            </p>
            <p
              v-if="taskOutcomeNote(task)"
              class="mb-0 line-clamp-2 whitespace-pre-wrap text-[11px] leading-3 text-n-slate-11"
            >
              <span class="font-medium text-n-slate-12">
                {{ taskResultNoteLabel(task) }}
              </span>
              {{ taskOutcomeNote(task) }}
            </p>
          </div>

          <div class="flex shrink-0 justify-end">
            <button
              v-if="canSetTaskResult(task)"
              type="button"
              class="inline-flex h-7 items-center gap-1 rounded-full border px-2 text-[11px] font-medium transition-colors"
              :class="taskResultButtonClass(task)"
              :aria-label="$t('CRM.TASKS.RESULT_DIALOG.ACTION')"
              @click="openTaskResultDialog(task)"
            >
              <span
                :class="taskResultActionIcon(task)"
                class="size-3"
                aria-hidden="true"
              />
              <span>{{ taskResultActionLabel(task) }}</span>
            </button>
          </div>
        </div>
      </li>
    </ol>
  </section>

  <Dialog
    ref="taskDialogRef"
    width="xl"
    overflow-y-auto
    :title="taskDialogTitle"
    :description="taskDialogDescription"
    :cancel-button-label="taskDialogCancelLabel"
    :confirm-button-label="taskDialogConfirmLabel"
    :disable-confirm-button="isTaskFormDisabled"
    :show-confirm-button="!isTaskReadOnly"
    :is-loading="ui.isSaving"
    @confirm="saveTask"
  >
    <div class="crm-task-dialog-form">
      <Input
        class="crm-task-dialog-control"
        custom-input-class="!rounded-md !bg-n-alpha-black2 !px-2 !py-1"
        :label="$t('CRM.TASKS.FORM.TITLE')"
        :model-value="form.title"
        :disabled="isTaskReadOnly"
        size="sm"
        @update:model-value="form.title = $event"
      />

      <div class="crm-task-dialog-grid">
        <SchedulingSelectField
          class="crm-task-dialog-control crm-task-dialog-select-control"
          :label="$t('CRM.TASKS.FORM.ACTIVITY_TYPE')"
          :model-value="form.activityType"
          :disabled="isTaskReadOnly"
          :options="activityTypeOptions"
          dropdown-placement="auto"
          @update:model-value="updateFormActivityType"
        />
        <SchedulingSelectField
          class="crm-task-dialog-control crm-task-dialog-select-control"
          :label="$t('CRM.TASKS.FORM.ASSIGNEE')"
          :model-value="form.assigneeId"
          :disabled="isTaskReadOnly"
          :options="assignees"
          dropdown-placement="auto"
          @update:model-value="form.assigneeId = $event"
        />
      </div>

      <div class="crm-task-dialog-grid">
        <SchedulingDateTimeField
          class="crm-task-dialog-control"
          input-class="!rounded-md !bg-n-alpha-black2 !px-2 !py-1"
          :label="$t('CRM.TASKS.FORM.START_AT')"
          :model-value="form.startAt"
          :disabled="isTaskReadOnly"
          type="datetime"
          @update:model-value="form.startAt = $event"
        />
        <SchedulingDateTimeField
          class="crm-task-dialog-control"
          input-class="!rounded-md !bg-n-alpha-black2 !px-2 !py-1"
          :label="$t('CRM.TASKS.FORM.DUE_AT')"
          :model-value="form.dueAt"
          :disabled="isTaskReadOnly"
          type="datetime"
          @update:model-value="form.dueAt = $event"
        />
      </div>

      <TextArea
        class="crm-task-dialog-control crm-task-dialog-textarea-control"
        :label="$t('CRM.TASKS.FORM.DESCRIPTION')"
        :model-value="form.description"
        :disabled="isTaskReadOnly"
        auto-height
        custom-text-area-wrapper-class="!rounded-md !border-n-weak !bg-n-alpha-black2 !px-2 !py-1.5 hover:!border-n-slate-6"
        min-height="3rem"
        max-height="none"
        @update:model-value="form.description = $event"
      />

      <CrmCustomFieldsSection
        v-if="applicableTaskFieldDefinitions.length"
        class="crm-task-dialog-custom-fields"
        :definitions="applicableTaskFieldDefinitions"
        :framed="false"
        layout="rows"
        :model-value="form.customAttributes"
        :disabled="isTaskReadOnly"
        @update:model-value="form.customAttributes = $event"
      />
    </div>
  </Dialog>

  <Dialog
    ref="waitingDialogRef"
    width="md"
    :title="$t('CRM.DEALS.WAITING.TITLE')"
    :description="$t('CRM.DEALS.WAITING.DESCRIPTION')"
    :confirm-button-label="$t('CRM.DEALS.WAITING.CONFIRM')"
    :disable-confirm-button="!waitingForm.until || !waitingForm.reason.trim()"
    :is-loading="ui.isSaving"
    @confirm="saveWaiting"
  >
    <div class="grid gap-4">
      <SchedulingDateTimeField
        :label="$t('CRM.DEALS.WAITING.UNTIL')"
        :model-value="waitingForm.until"
        type="datetime"
        @update:model-value="waitingForm.until = $event"
      />
      <TextArea
        :label="$t('CRM.DEALS.WAITING.REASON')"
        :model-value="waitingForm.reason"
        auto-height
        @update:model-value="waitingForm.reason = $event"
      />
      <label
        v-if="canManageTasks"
        class="flex items-center gap-2 text-sm text-n-slate-12"
      >
        <input
          v-model="waitingForm.createWakeUpTask"
          type="checkbox"
          class="size-4 rounded border-n-strong text-n-brand focus:ring-n-brand"
        />
        <span>{{ $t('CRM.DEALS.WAITING.CREATE_WAKE_UP_TASK') }}</span>
      </label>
    </div>
  </Dialog>

  <CrmTaskCompletionDialog
    ref="resultDialogRef"
    :is-loading="ui.isSaving"
    :task-types="taskTypes"
    @confirm="saveTaskResult"
  />
</template>

<style scoped>
.crm-task-dialog-form {
  @apply grid gap-3;
}

.crm-task-dialog-grid {
  @apply grid gap-2 md:grid-cols-2;
}

.crm-task-dialog-control,
.crm-task-dialog-form :deep(.crm-task-dialog-control) {
  width: 100%;
  min-width: 0;
}

.crm-task-dialog-form :deep(.crm-task-dialog-control label),
.crm-task-dialog-form :deep(.crm-task-dialog-control > span:first-child) {
  @apply mb-0 text-[13px] font-medium leading-4 text-n-slate-12;
}

.crm-task-dialog-form :deep(.crm-task-dialog-control input),
.crm-task-dialog-form
  :deep(.crm-task-dialog-control .reka-date-time-picker__input),
.crm-task-dialog-form
  :deep(.crm-task-dialog-control .reka-date-time-picker__trigger),
.crm-task-dialog-form :deep(.crm-task-dialog-select-control button) {
  @apply border border-n-weak bg-n-alpha-black2 text-sm font-normal text-n-slate-12 shadow-none outline outline-1 outline-transparent transition-colors duration-150 !important;
  border-radius: 0.375rem !important;
  height: 2rem !important;
  min-height: 2rem !important;
}

.crm-task-dialog-form :deep(.crm-task-dialog-control input),
.crm-task-dialog-form
  :deep(.crm-task-dialog-control .reka-date-time-picker__input),
.crm-task-dialog-form
  :deep(.crm-task-dialog-control .reka-date-time-picker__trigger),
.crm-task-dialog-form :deep(.crm-task-dialog-select-control button) {
  @apply px-2 py-1 !important;
}

.crm-task-dialog-form :deep(.crm-task-dialog-control input:hover),
.crm-task-dialog-form
  :deep(.crm-task-dialog-control .reka-date-time-picker__input:hover),
.crm-task-dialog-form
  :deep(.crm-task-dialog-control .reka-date-time-picker__trigger:hover),
.crm-task-dialog-form :deep(.crm-task-dialog-select-control button:hover) {
  @apply border-n-slate-6 bg-n-alpha-black2 outline-transparent !important;
}

.crm-task-dialog-form :deep(.crm-task-dialog-control input:focus),
.crm-task-dialog-form
  :deep(.crm-task-dialog-control .reka-date-time-picker__input:focus),
.crm-task-dialog-form
  :deep(.crm-task-dialog-control .reka-date-time-picker__trigger:focus),
.crm-task-dialog-form
  :deep(
    .crm-task-dialog-control .reka-date-time-picker__trigger[data-state='open']
  ),
.crm-task-dialog-form :deep(.crm-task-dialog-select-control button:focus),
.crm-task-dialog-form
  :deep(.crm-task-dialog-select-control button[data-state='open']) {
  @apply border-n-weak bg-n-alpha-black2 outline-n-brand !important;
}

.crm-task-dialog-form :deep(.crm-task-dialog-textarea-control textarea) {
  @apply text-sm font-normal text-n-slate-12 !important;
}

.crm-task-dialog-custom-fields {
  @apply border-t border-n-weak pt-3;
}
</style>
