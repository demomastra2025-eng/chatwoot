<script setup>
import { computed, onMounted, reactive, ref, watch } from 'vue';
import { format } from 'date-fns';
import { useI18n } from 'vue-i18n';
import { useRoute, useRouter } from 'vue-router';

import CrmDealsAPI from 'dashboard/api/crm/deals';
import CrmTasksAPI from 'dashboard/api/crm/tasks';
import { useAlert } from 'dashboard/composables';
import { useMapGetter, useStore } from 'dashboard/composables/store';
import { usePolicy } from 'dashboard/composables/usePolicy';
import {
  CRM_TASK_MANAGE_PERMISSION,
  CRM_TASK_VIEW_PERMISSION,
} from 'dashboard/constants/permissions';
import Button from 'dashboard/components-next/button/Button.vue';
import Checkbox from 'dashboard/components-next/checkbox/Checkbox.vue';
import Dialog from 'dashboard/components-next/dialog/Dialog.vue';
import Icon from 'dashboard/components-next/icon/Icon.vue';
import Input from 'dashboard/components-next/input/Input.vue';
import Spinner from 'dashboard/components-next/spinner/Spinner.vue';
import TextArea from 'dashboard/components-next/textarea/TextArea.vue';
import CrmCustomFieldsSection from 'dashboard/components-next/CRM/CrmCustomFieldsSection.vue';
import CrmTaskBoard from 'dashboard/components-next/CRM/CrmTaskBoard.vue';
import CrmTaskCalendar from 'dashboard/components-next/CRM/CrmTaskCalendar.vue';
import CrmTimelineFeed from 'dashboard/components-next/CRM/CrmTimelineFeed.vue';
import PaginationFooter from 'dashboard/components-next/pagination/PaginationFooter.vue';
import SchedulingDateTimeField from 'dashboard/components-next/Scheduling/SchedulingDateTimeField.vue';
import SchedulingDrawer from 'dashboard/components-next/Scheduling/SchedulingDrawer.vue';
import SchedulingEmptyState from 'dashboard/components-next/Scheduling/SchedulingEmptyState.vue';
import SchedulingErrorState from 'dashboard/components-next/Scheduling/SchedulingErrorState.vue';
import SchedulingFormFieldGroup from 'dashboard/components-next/Scheduling/SchedulingFormFieldGroup.vue';
import SchedulingPageHeader from 'dashboard/components-next/Scheduling/SchedulingPageHeader.vue';
import SchedulingRecordTable from 'dashboard/components-next/Scheduling/SchedulingRecordTable.vue';
import SchedulingSelectField from 'dashboard/components-next/Scheduling/SchedulingSelectField.vue';
import SchedulingToolbar from 'dashboard/components-next/Scheduling/SchedulingToolbar.vue';
import SchedulingViewSwitcher from 'dashboard/components-next/Scheduling/SchedulingViewSwitcher.vue';
import {
  buildCalendarRange,
  formatCalendarTitle,
  shiftAnchorDate,
  toDateTimeInputValue,
} from 'dashboard/routes/dashboard/scheduling/helpers';
import { useCrmReferencesStore } from 'dashboard/stores/crm/references';
import {
  compactPayload,
  formatCrmErrorMessage,
  normalizePayload,
} from 'dashboard/stores/crm/shared';
import { DEFAULT_TASK_STATUS_COLOR } from 'dashboard/stores/crm/taskStatusColors';

const referencesStore = useCrmReferencesStore();
const store = useStore();
const route = useRoute();
const router = useRouter();
const { checkPermissions } = usePolicy();
const { locale, t } = useI18n();

const tasks = ref([]);
const dealOptions = ref([]);
const currentPresentation = ref('list');
const currentCalendarView = ref('week');
const calendarAnchorDate = ref(new Date());
const drawerOpen = ref(false);
const filterDialogRef = ref(null);
const listCurrentPage = ref(1);
const selectedTask = ref(null);
const timelineItems = ref([]);

const LIST_PAGE_SIZE = 25;

const filters = reactive({
  archived: false,
  assigneeId: '',
  priority: '',
  statusId: '',
  teamId: '',
});
const filterDraft = reactive({
  archived: false,
  assigneeId: '',
  priority: '',
  statusId: '',
  teamId: '',
});
const listQuickFilters = reactive({
  q: '',
});

const form = reactive({
  assigneeId: '',
  customAttributes: {},
  dealId: '',
  description: '',
  dueAt: '',
  externalRef: '',
  originatingConversationDisplayId: '',
  originatingConversationId: '',
  priority: 'medium',
  startAt: '',
  statusId: '',
  teamId: '',
  title: '',
});

const ui = reactive({
  error: null,
  isLoading: false,
  isSaving: false,
  isSavingComment: false,
  isTimelineLoading: false,
});

const accountId = useMapGetter('getCurrentAccountId');
const agents = useMapGetter('agents/getAgents');
const currentUser = useMapGetter('getCurrentUser');
const teams = useMapGetter('teams/getTeams');

const canManageTasks = computed(() =>
  checkPermissions(['administrator', CRM_TASK_MANAGE_PERMISSION])
);
const canViewTasks = computed(() =>
  checkPermissions([
    'administrator',
    'agent',
    CRM_TASK_VIEW_PERMISSION,
    CRM_TASK_MANAGE_PERMISSION,
  ])
);

const taskStatusOptions = computed(() =>
  referencesStore.taskStatuses.map(status => ({
    label: status.name,
    value: status.id,
  }))
);

const taskStatusCategoryMeta = {
  done: {
    icon: 'i-lucide-check-circle',
    toneClass: 'text-n-teal-11',
  },
  in_progress: {
    icon: 'i-lucide-clock-3',
    toneClass: 'text-n-amber-11',
  },
  open: {
    icon: 'i-lucide-circle',
    toneClass: 'text-n-slate-11',
  },
};

const hasBoardStatuses = computed(
  () => referencesStore.taskStatuses.length > 0
);

const shouldRenderBoard = computed(
  () => currentPresentation.value === 'board' && hasBoardStatuses.value
);

const assigneeOptions = computed(() =>
  agents.value.map(agent => ({
    label: agent.name || agent.email,
    thumbnail: {
      name: agent.name || agent.email,
    },
    value: agent.id,
  }))
);

const teamOptions = computed(() =>
  teams.value.map(team => ({
    label: team.name,
    value: team.id,
  }))
);

const currentUserId = computed(() => {
  const userId = Number(currentUser.value?.id);
  return Number.isFinite(userId) && userId > 0 ? userId : '';
});

const applicableTaskFieldDefinitions = computed(() => {
  const context = form.dealId ? 'deal_task' : 'standalone_task';

  return referencesStore.taskFieldDefinitions.filter(definition => {
    const contexts = definition.rules?.contexts || [];
    return contexts.length === 0 || contexts.includes(context);
  });
});

const statusNameById = computed(() =>
  referencesStore.taskStatuses.reduce((result, status) => {
    result[status.id] = status.name;
    return result;
  }, {})
);

const statusColorById = computed(() =>
  referencesStore.taskStatuses.reduce((result, status) => {
    result[status.id] = status.color;
    return result;
  }, {})
);

const assigneeNameById = computed(() =>
  agents.value.reduce((result, agent) => {
    result[agent.id] = agent.name || agent.email;
    return result;
  }, {})
);

const dealNameById = computed(() =>
  dealOptions.value.reduce((result, deal) => {
    result[deal.value] = deal.label;
    return result;
  }, {})
);

const priorityOptions = computed(() => [
  { label: t('CRM.TASKS.PRIORITY.low'), value: 'low' },
  { label: t('CRM.TASKS.PRIORITY.medium'), value: 'medium' },
  { label: t('CRM.TASKS.PRIORITY.high'), value: 'high' },
  { label: t('CRM.TASKS.PRIORITY.urgent'), value: 'urgent' },
]);

const priorityMetaByValue = computed(() => ({
  high: {
    icon: 'i-lucide-arrow-up',
    label: t('CRM.TASKS.PRIORITY.high'),
    toneClass: 'text-n-ruby-11',
  },
  low: {
    icon: 'i-lucide-arrow-down',
    label: t('CRM.TASKS.PRIORITY.low'),
    toneClass: 'text-n-slate-11',
  },
  medium: {
    icon: 'i-lucide-arrow-right',
    label: t('CRM.TASKS.PRIORITY.medium'),
    toneClass: 'text-n-amber-11',
  },
  urgent: {
    icon: 'i-lucide-arrow-up',
    label: t('CRM.TASKS.PRIORITY.urgent'),
    toneClass: 'text-n-ruby-11',
  },
}));

const statusMetaById = computed(() =>
  referencesStore.taskStatuses.reduce((result, status) => {
    const categoryMeta =
      taskStatusCategoryMeta[status.category] || taskStatusCategoryMeta.open;

    result[status.id] = {
      color: status.color || DEFAULT_TASK_STATUS_COLOR,
      icon: categoryMeta.icon,
      label: status.name,
      toneClass: categoryMeta.toneClass,
    };
    return result;
  }, {})
);

const hasListSearchQuery = computed(() => listQuickFilters.q.trim().length > 0);

const viewOptions = computed(() => [
  { label: t('CRM.VIEWS.LIST'), value: 'list' },
  { label: t('CRM.VIEWS.BOARD'), value: 'board' },
  { label: t('SCHEDULING.VIEWS.CALENDAR'), value: 'calendar' },
]);

const calendarViewOptions = computed(() => [
  { label: t('SCHEDULING.VIEWS.DAY'), value: 'day' },
  { label: t('SCHEDULING.VIEWS.WEEK'), value: 'week' },
  { label: t('SCHEDULING.VIEWS.MONTH'), value: 'month' },
]);

const calendarLabel = computed(() =>
  formatCalendarTitle(
    currentCalendarView.value,
    calendarAnchorDate.value,
    locale.value
  )
);

const tableColumns = computed(() => [
  { key: 'id', label: t('CRM.GENERAL.ID'), width: '72px' },
  { key: 'title', label: t('CRM.TASKS.TABLE.TITLE'), width: '2.4fr' },
  { key: 'status', label: t('CRM.TASKS.TABLE.STATUS'), width: '1fr' },
  {
    key: 'priority',
    label: t('CRM.TASKS.FORM.PRIORITY'),
    width: '0.95fr',
  },
  { key: 'assignee', label: t('CRM.TASKS.TABLE.ASSIGNEE'), width: '1fr' },
  { key: 'dueAt', label: t('CRM.TASKS.TABLE.DUE_AT'), width: '1fr' },
  { key: 'actions', label: '', width: '112px', align: 'end' },
]);

const normalizeFilterText = value =>
  String(value || '')
    .trim()
    .toLowerCase();

const filteredListTasks = computed(() => {
  const search = normalizeFilterText(listQuickFilters.q);

  return tasks.value.filter(task => {
    if (!search) {
      return true;
    }

    return [
      task.title,
      task.description,
      `#${task.id}`,
      dealNameById.value[task.dealId],
      assigneeNameById.value[task.assigneeId],
    ].some(value => normalizeFilterText(value).includes(search));
  });
});

const paginatedListTasks = computed(() => {
  const startIndex = (listCurrentPage.value - 1) * LIST_PAGE_SIZE;
  return filteredListTasks.value.slice(startIndex, startIndex + LIST_PAGE_SIZE);
});

const stripedTaskRowIds = computed(
  () =>
    new Set(
      paginatedListTasks.value
        .filter((_, index) => index % 2 === 1)
        .map(task => Number(task.id))
    )
);

const shouldShowListPagination = computed(
  () => filteredListTasks.value.length > LIST_PAGE_SIZE
);

const taskListRowClass = row => [
  row.archivedAt ? 'opacity-75' : '',
  stripedTaskRowIds.value.has(Number(row.id)) ? 'bg-n-surface-1/70' : '',
];

const defaultCustomAttributes = definitions => {
  return definitions.reduce((result, definition) => {
    if (
      definition.defaultValue !== null &&
      definition.defaultValue !== undefined
    ) {
      result[definition.key] = definition.defaultValue;
    }
    return result;
  }, {});
};

const resetForm = () => {
  const defaultStatus =
    referencesStore.taskStatuses.find(status => status.default) ||
    referencesStore.taskStatuses[0];

  Object.assign(form, {
    assigneeId: currentUserId.value,
    customAttributes: defaultCustomAttributes(
      referencesStore.taskFieldDefinitions
    ),
    dealId: '',
    description: '',
    dueAt: '',
    externalRef: '',
    originatingConversationDisplayId: '',
    originatingConversationId: '',
    priority: 'medium',
    startAt: '',
    statusId: defaultStatus?.id || '',
    teamId: '',
    title: '',
  });
};

const formatErrorMessage = error => formatCrmErrorMessage(error, t);

const formatDate = value => {
  if (!value) return t('CRM.GENERAL.EMPTY_VALUE');
  return format(new Date(value), 'MMM d, yyyy HH:mm');
};

const crmPrefillKeys = [
  'action',
  'assigneeId',
  'contactName',
  'conversationDisplayId',
  'originatingConversationId',
  'source',
  'teamId',
];

const queryValue = key => {
  const value = route.query[key];
  return Array.isArray(value) ? value[0] : value;
};

const numericQueryValue = key => {
  const value = Number(queryValue(key));
  return Number.isFinite(value) && value > 0 ? value : '';
};

const buildPrefillTaskTitle = () => {
  const contactName = queryValue('contactName');
  const conversationDisplayId = queryValue('conversationDisplayId');

  if (contactName) {
    return t('CRM.TASKS.PREFILL.CONVERSATION_WITH_CONTACT', {
      contactName,
    });
  }

  if (conversationDisplayId) {
    return t('CRM.TASKS.PREFILL.CONVERSATION_GENERIC', {
      conversationId: conversationDisplayId,
    });
  }

  return '';
};

const loadDealOptions = async () => {
  const { data } = await CrmDealsAPI.get({ archived: false });
  dealOptions.value = normalizePayload(data).map(deal => ({
    label: deal.title,
    value: deal.id,
  }));
};

const loadTimeline = async taskId => {
  ui.isTimelineLoading = true;

  try {
    const { data } = await CrmTasksAPI.timeline(taskId, { limit: 50 });
    timelineItems.value = normalizePayload(data);
  } finally {
    ui.isTimelineLoading = false;
  }
};

const openCreateDrawer = async prefill => {
  selectedTask.value = null;
  resetForm();
  timelineItems.value = [];
  drawerOpen.value = true;
  await loadDealOptions();

  if (prefill) {
    Object.assign(form, prefill);
  }
};

const openCalendarCreateDrawer = async payload => {
  if (!canManageTasks.value) {
    return;
  }

  await openCreateDrawer({
    dueAt: toDateTimeInputValue(payload?.endsAt),
    startAt: toDateTimeInputValue(payload?.startsAt),
  });
};

const openEditDrawer = async task => {
  selectedTask.value = task;
  Object.assign(form, {
    assigneeId: task.assigneeId ?? '',
    customAttributes: { ...(task.customAttributes || {}) },
    dealId: task.dealId ?? '',
    description: task.description || '',
    dueAt: task.dueAt ? task.dueAt.slice(0, 16) : '',
    externalRef: task.externalRef || '',
    originatingConversationDisplayId: task.originatingConversationId
      ? `#${task.originatingConversationId}`
      : '',
    originatingConversationId: task.originatingConversationId ?? '',
    priority: task.priority || 'medium',
    startAt: task.startAt ? task.startAt.slice(0, 16) : '',
    statusId: task.statusId,
    teamId: task.teamId ?? '',
    title: task.title,
  });
  drawerOpen.value = true;
  await loadDealOptions();
  await loadTimeline(task.id);
};

const closeDrawer = () => {
  drawerOpen.value = false;
  selectedTask.value = null;
  timelineItems.value = [];
  resetForm();
};

const upsertTask = task => {
  const existingIndex = tasks.value.findIndex(item => item.id === task.id);

  if (existingIndex === -1) {
    tasks.value = [task, ...tasks.value];
    return;
  }

  const nextTasks = [...tasks.value];
  nextTasks.splice(existingIndex, 1, task);
  tasks.value = nextTasks;
};

const syncSelectedTask = records => {
  if (!selectedTask.value) return;

  const nextSelectedTask = records.find(
    task => Number(task.id) === Number(selectedTask.value.id)
  );

  if (nextSelectedTask) {
    selectedTask.value = nextSelectedTask;
  }
};

const buildPayload = () => {
  return compactPayload({
    assignee_id: form.assigneeId ? Number(form.assigneeId) : undefined,
    custom_attributes: form.customAttributes,
    deal_id: form.dealId ? Number(form.dealId) : undefined,
    description: form.description || undefined,
    due_at: form.dueAt || undefined,
    external_ref: form.externalRef || undefined,
    lock_version: selectedTask.value?.lockVersion,
    originating_conversation_id: form.originatingConversationId
      ? Number(form.originatingConversationId)
      : undefined,
    priority: form.priority || undefined,
    start_at: form.startAt || undefined,
    status_id: form.statusId ? Number(form.statusId) : undefined,
    team_id: form.teamId ? Number(form.teamId) : undefined,
    title: form.title.trim(),
  });
};

const saveTask = async () => {
  ui.isSaving = true;

  try {
    const payload = buildPayload();
    let task;

    if (selectedTask.value) {
      const currentStatusId = selectedTask.value.statusId;
      const { status_id: _statusId, ...updatePayload } = payload;
      const response = await CrmTasksAPI.update(
        selectedTask.value.id,
        updatePayload
      );
      task = normalizePayload(response.data);

      if (Number(form.statusId) !== Number(currentStatusId) && form.statusId) {
        const transitionResponse = await CrmTasksAPI.changeStatus(task.id, {
          lock_version: task.lockVersion,
          status_id: Number(form.statusId),
        });
        task = normalizePayload(transitionResponse.data);
      }
    } else {
      const response = await CrmTasksAPI.create(payload);
      task = normalizePayload(response.data);
    }

    upsertTask(task);
    useAlert(
      selectedTask.value
        ? t('CRM.TASKS.SUCCESS_UPDATED')
        : t('CRM.TASKS.SUCCESS_CREATED')
    );
    closeDrawer();
  } catch (error) {
    useAlert(formatErrorMessage(error));
  } finally {
    ui.isSaving = false;
  }
};

const toggleArchived = async task => {
  try {
    const response = task.archivedAt
      ? await CrmTasksAPI.unarchive(task.id, { lock_version: task.lockVersion })
      : await CrmTasksAPI.archive(task.id, { lock_version: task.lockVersion });
    const updatedTask = normalizePayload(response.data);
    upsertTask(updatedTask);
    syncSelectedTask(tasks.value);
    useAlert(
      task.archivedAt
        ? t('CRM.TASKS.SUCCESS_UNARCHIVED')
        : t('CRM.TASKS.SUCCESS_ARCHIVED')
    );
  } catch (error) {
    useAlert(formatErrorMessage(error));
  }
};

const loadTasks = async () => {
  ui.isLoading = true;
  ui.error = null;

  try {
    const query = compactPayload({
      archived: filters.archived,
      assignee_id: filters.assigneeId || undefined,
      priority: filters.priority || undefined,
      status_id: filters.statusId || undefined,
      team_id: filters.teamId || undefined,
    });

    if (currentPresentation.value === 'calendar') {
      const { from, to } = buildCalendarRange(
        currentCalendarView.value,
        calendarAnchorDate.value
      );

      query.due_from = from.toISOString();
      query.due_to = new Date(to.getTime() + 1).toISOString();
    }

    const { data } = await CrmTasksAPI.get(query);
    tasks.value = normalizePayload(data);
    syncSelectedTask(tasks.value);
  } catch (error) {
    ui.error = error;
  } finally {
    ui.isLoading = false;
  }
};

const saveComment = async body => {
  if (!selectedTask.value) return;

  ui.isSavingComment = true;
  try {
    await CrmTasksAPI.createComment(selectedTask.value.id, { body });
    await loadTimeline(selectedTask.value.id);
  } catch (error) {
    useAlert(formatErrorMessage(error));
  } finally {
    ui.isSavingComment = false;
  }
};

const deleteComment = async comment => {
  if (!selectedTask.value) return;

  ui.isSavingComment = true;
  try {
    await CrmTasksAPI.deleteComment(selectedTask.value.id, comment.id);
    await loadTimeline(selectedTask.value.id);
  } catch (error) {
    useAlert(formatErrorMessage(error));
  } finally {
    ui.isSavingComment = false;
  }
};

const clearTaskPrefillQuery = async () => {
  const nextQuery = { ...route.query };
  crmPrefillKeys.forEach(key => {
    delete nextQuery[key];
  });

  await router.replace({ query: nextQuery });
};

const consumeTaskPrefillQuery = async () => {
  if (queryValue('action') !== 'new') return;

  await openCreateDrawer({
    assigneeId: numericQueryValue('assigneeId'),
    originatingConversationDisplayId: queryValue('conversationDisplayId')
      ? `#${queryValue('conversationDisplayId')}`
      : '',
    originatingConversationId: numericQueryValue('originatingConversationId'),
    teamId: numericQueryValue('teamId'),
    title: buildPrefillTaskTitle(),
  });
  await clearTaskPrefillQuery();
};

const handlePresentationChange = async presentation => {
  currentPresentation.value = presentation;
  await loadTasks();
};

const syncFilterDraft = () => {
  Object.assign(filterDraft, {
    archived: filters.archived,
    assigneeId: filters.assigneeId,
    priority: filters.priority,
    statusId: filters.statusId,
    teamId: filters.teamId,
  });
};

const openFilterDialog = () => {
  syncFilterDraft();
  filterDialogRef.value?.open();
};

const applyFilters = async () => {
  listCurrentPage.value = 1;
  Object.assign(filters, {
    archived: filterDraft.archived,
    assigneeId: filterDraft.assigneeId,
    priority: filterDraft.priority,
    statusId: filterDraft.statusId,
    teamId: filterDraft.teamId,
  });
  filterDialogRef.value?.close();
  await loadTasks();
};

watch(
  () => listQuickFilters.q,
  () => {
    listCurrentPage.value = 1;
  }
);

watch(filteredListTasks, rows => {
  if (!rows.length) {
    listCurrentPage.value = 1;
    return;
  }

  const maxPage = Math.max(1, Math.ceil(rows.length / LIST_PAGE_SIZE));

  if (listCurrentPage.value > maxPage) {
    listCurrentPage.value = maxPage;
  }
});

const openCreateTaskStatusSetup = () => {
  if (!canManageTasks.value) return;

  router.push({
    name: 'crm_settings_index',
    params: { accountId: accountId.value },
    query: {
      action: 'create-task-status',
    },
  });
};

const handleBoardCreateTask = async ({ statusId }) => {
  await openCreateDrawer({
    statusId,
  });
};

const handleTaskStatusChange = async ({ task, statusId }) => {
  const currentTask =
    tasks.value.find(item => Number(item.id) === Number(task.id)) || task;
  const nextStatusId = Number(statusId);

  if (!nextStatusId || Number(currentTask.statusId) === nextStatusId) {
    return;
  }

  const optimisticTask = { ...currentTask, statusId: nextStatusId };
  upsertTask(optimisticTask);

  if (
    selectedTask.value &&
    Number(selectedTask.value.id) === optimisticTask.id
  ) {
    selectedTask.value = optimisticTask;
    form.statusId = nextStatusId;
  }

  try {
    const response = await CrmTasksAPI.changeStatus(currentTask.id, {
      lock_version: currentTask.lockVersion,
      status_id: nextStatusId,
    });
    const updatedTask = normalizePayload(response.data);
    upsertTask(updatedTask);

    if (
      selectedTask.value &&
      Number(selectedTask.value.id) === updatedTask.id
    ) {
      selectedTask.value = updatedTask;
      form.statusId = updatedTask.statusId;
    }
  } catch (error) {
    try {
      await loadTasks();
    } catch {
      // Keep the original API error as the surfaced failure.
    }

    useAlert(formatErrorMessage(error));
  }
};

const handleTaskAssigneeChange = async ({ task, assigneeId }) => {
  const currentTask =
    tasks.value.find(item => Number(item.id) === Number(task.id)) || task;
  const nextAssigneeId = Number(assigneeId);

  if (!nextAssigneeId || Number(currentTask.assigneeId) === nextAssigneeId) {
    return;
  }

  const optimisticTask = { ...currentTask, assigneeId: nextAssigneeId };
  upsertTask(optimisticTask);

  if (
    selectedTask.value &&
    Number(selectedTask.value.id) === optimisticTask.id
  ) {
    selectedTask.value = optimisticTask;
    form.assigneeId = nextAssigneeId;
  }

  try {
    const response = await CrmTasksAPI.update(currentTask.id, {
      assignee_id: nextAssigneeId,
      lock_version: currentTask.lockVersion,
    });
    const updatedTask = normalizePayload(response.data);
    upsertTask(updatedTask);

    if (
      selectedTask.value &&
      Number(selectedTask.value.id) === updatedTask.id
    ) {
      selectedTask.value = updatedTask;
      form.assigneeId = updatedTask.assigneeId;
    }
  } catch (error) {
    try {
      await loadTasks();
    } catch {
      // Keep the original API error as the surfaced failure.
    }

    useAlert(formatErrorMessage(error));
  }
};

const syncTaskRangeInDrawer = task => {
  if (
    !selectedTask.value ||
    Number(selectedTask.value.id) !== Number(task.id)
  ) {
    return;
  }

  selectedTask.value = task;
  form.startAt = task.startAt ? task.startAt.slice(0, 16) : '';
  form.dueAt = task.dueAt ? task.dueAt.slice(0, 16) : '';
};

const updateTaskCalendarRange = async ({ task, startsAt, endsAt }) => {
  if (!canManageTasks.value) {
    return;
  }

  const currentTask =
    tasks.value.find(item => Number(item.id) === Number(task?.id)) || task;

  if (!currentTask?.id) {
    return;
  }

  const previousTask = { ...currentTask };
  const optimisticTask = {
    ...currentTask,
    dueAt: endsAt,
    startAt: startsAt,
  };

  upsertTask(optimisticTask);
  syncTaskRangeInDrawer(optimisticTask);

  try {
    const response = await CrmTasksAPI.update(currentTask.id, {
      due_at: endsAt,
      lock_version: currentTask.lockVersion,
      start_at: startsAt,
    });
    const updatedTask = normalizePayload(response.data);
    upsertTask(updatedTask);
    syncTaskRangeInDrawer(updatedTask);
  } catch (error) {
    upsertTask(previousTask);
    syncTaskRangeInDrawer(previousTask);

    try {
      await loadTasks();
    } catch {
      // Keep the original API error as the surfaced failure.
    }

    useAlert(formatErrorMessage(error));
  }
};

const selectCalendarView = async view => {
  currentCalendarView.value = view;
  await loadTasks();
};

const shiftCalendar = async direction => {
  calendarAnchorDate.value = shiftAnchorDate(
    currentCalendarView.value,
    calendarAnchorDate.value,
    direction
  );
  await loadTasks();
};

const selectCalendarDate = async value => {
  calendarAnchorDate.value = value || new Date();
  await loadTasks();
};

const jumpCalendarToToday = async () => {
  calendarAnchorDate.value = new Date();
  await loadTasks();
};

onMounted(async () => {
  if (!canViewTasks.value) return;

  if (!agents.value.length) {
    await store.dispatch('agents/get');
  }

  if (!teams.value.length) {
    await store.dispatch('teams/get');
  }

  await Promise.all([
    referencesStore.loadTaskStatuses(),
    referencesStore.loadFieldDefinitions('task'),
    loadDealOptions(),
  ]);
  resetForm();
  await loadTasks();
  await consumeTaskPrefillQuery();
});
</script>

<template>
  <section class="flex flex-1 min-h-0 flex-col overflow-hidden bg-n-slate-2">
    <SchedulingPageHeader class="!bg-n-slate-2" :title="$t('CRM.TASKS.TITLE')">
      <template #actions>
        <Input
          v-if="currentPresentation === 'list'"
          size="sm"
          type="search"
          :model-value="listQuickFilters.q"
          :placeholder="$t('CRM.TASKS.LIST.SEARCH_PLACEHOLDER')"
          class="w-full sm:w-72"
          custom-input-class="ltr:!pr-8 rtl:!pl-8"
          @update:model-value="listQuickFilters.q = $event"
        >
          <template #suffix>
            <Icon
              icon="i-lucide-search"
              class="absolute top-1/2 size-4 -translate-y-1/2 text-n-slate-11 ltr:right-2 rtl:left-2"
            />
          </template>
        </Input>
        <Button
          size="sm"
          color="slate"
          variant="outline"
          icon="i-lucide-filter"
          @click="openFilterDialog"
        />
        <SchedulingViewSwitcher
          :model-value="currentPresentation"
          :views="viewOptions"
          @update:model-value="handlePresentationChange"
        />
        <Button
          v-if="canManageTasks"
          size="sm"
          icon="i-lucide-plus"
          :label="$t('CRM.TASKS.NEW_TASK')"
          @click="openCreateDrawer"
        />
      </template>
    </SchedulingPageHeader>

    <SchedulingToolbar
      v-if="currentPresentation === 'calendar'"
      transparent
      :current-label="calendarLabel"
      :anchor-date="calendarAnchorDate"
      :model-value="currentCalendarView"
      :views="calendarViewOptions"
      @next="shiftCalendar(1)"
      @previous="shiftCalendar(-1)"
      @select-date="selectCalendarDate"
      @today="jumpCalendarToToday"
      @update:model-value="selectCalendarView"
    />

    <div
      class="flex-1"
      :class="
        (currentPresentation === 'calendar' || shouldRenderBoard) &&
        !ui.isLoading &&
        !ui.error
          ? 'min-h-0 overflow-hidden'
          : 'overflow-y-auto'
      "
    >
      <div
        :class="
          (currentPresentation === 'calendar' || shouldRenderBoard) &&
          !ui.isLoading &&
          !ui.error
            ? 'flex h-full min-h-0 flex-col px-5 pb-5 pt-3'
            : 'flex flex-col gap-4 px-5 pb-5 pt-3'
        "
      >
        <div v-if="ui.isLoading" class="flex justify-center py-16">
          <Spinner class="!h-8 !w-8" />
        </div>

        <SchedulingErrorState
          v-else-if="ui.error"
          :title="$t('CRM.ERRORS.LOAD_TITLE')"
          :description="formatErrorMessage(ui.error)"
          @retry="loadTasks"
        />

        <SchedulingEmptyState
          v-else-if="currentPresentation === 'board' && !hasBoardStatuses"
          icon="i-lucide-columns-3"
          :title="$t('CRM.TASKS.BOARD.EMPTY_STATUS_TITLE')"
          :description="$t('CRM.TASKS.BOARD.EMPTY_STATUS_DESCRIPTION')"
          :action-label="
            canManageTasks ? $t('CRM.TASKS.BOARD.CREATE_STATUS') : ''
          "
          @action="openCreateTaskStatusSetup"
        />

        <SchedulingEmptyState
          v-else-if="tasks.length === 0 && currentPresentation === 'list'"
          icon="i-lucide-list-todo"
          :title="$t('CRM.TASKS.EMPTY_TITLE')"
          :description="$t('CRM.TASKS.EMPTY_DESCRIPTION')"
          :action-label="canManageTasks ? $t('CRM.TASKS.NEW_TASK') : ''"
          @action="openCreateDrawer"
        />

        <div
          v-else-if="currentPresentation === 'list'"
          class="mt-3 overflow-hidden rounded-xl outline outline-1 outline-n-container"
        >
          <SchedulingRecordTable
            borderless
            class="crm-task-list-table !rounded-none !bg-transparent"
            :columns="tableColumns"
            :rows="paginatedListTasks"
            :row-class="taskListRowClass"
          >
            <template #empty>
              {{
                hasListSearchQuery
                  ? $t('CRM.TASKS.LIST.EMPTY_FILTERED')
                  : $t('SCHEDULING.GENERAL.NO_DATA')
              }}
            </template>

            <template #cell-id="{ row }">
              <span class="text-xs font-medium tabular-nums text-n-slate-11">
                {{ `#${row.id}` }}
              </span>
            </template>

            <template #cell-title="{ row }">
              <button
                type="button"
                class="grid w-full gap-0.5 border-0 bg-transparent p-0 text-left"
                @click="openEditDrawer(row)"
              >
                <span class="flex flex-wrap items-center gap-2">
                  <span class="font-medium text-n-slate-12">
                    {{ row.title }}
                  </span>
                  <span
                    v-if="row.dealId"
                    class="rounded-md border border-n-weak bg-n-surface-1 px-1.5 py-0.5 text-[10px] font-medium text-n-slate-11"
                  >
                    {{
                      dealNameById[row.dealId] || $t('CRM.GENERAL.EMPTY_VALUE')
                    }}
                  </span>
                  <span
                    v-if="row.archivedAt"
                    class="rounded-md bg-n-amber-9/10 px-1.5 py-0.5 text-[10px] font-medium text-n-amber-11"
                  >
                    {{ $t('CRM.GENERAL.ARCHIVED') }}
                  </span>
                </span>
                <span
                  v-if="row.description"
                  class="line-clamp-1 text-xs text-n-slate-11"
                >
                  {{ row.description }}
                </span>
              </button>
            </template>

            <template #cell-status="{ row }">
              <span
                class="inline-flex items-center gap-2 text-sm text-n-slate-12"
              >
                <span
                  class="inline-flex size-5 shrink-0 items-center justify-center rounded-full bg-n-alpha-black2"
                >
                  <span
                    class="size-3"
                    :class="[
                      statusMetaById[row.statusId]?.icon || 'i-lucide-circle',
                      statusMetaById[row.statusId]?.toneClass ||
                        'text-n-slate-11',
                    ]"
                    aria-hidden="true"
                  />
                </span>
                <span class="inline-flex items-center gap-2">
                  <span
                    class="size-2 rounded-full"
                    :style="{
                      backgroundColor:
                        statusColorById[row.statusId] ||
                        DEFAULT_TASK_STATUS_COLOR,
                    }"
                  />
                  <span>
                    {{
                      statusNameById[row.statusId] ||
                      $t('CRM.GENERAL.EMPTY_VALUE')
                    }}
                  </span>
                </span>
              </span>
            </template>

            <template #cell-priority="{ row }">
              <span
                class="inline-flex items-center gap-2 text-sm text-n-slate-12"
              >
                <span
                  class="size-4"
                  :class="[
                    priorityMetaByValue[row.priority]?.icon || 'i-lucide-minus',
                    priorityMetaByValue[row.priority]?.toneClass ||
                      'text-n-slate-10',
                  ]"
                  aria-hidden="true"
                />
                <span>
                  {{
                    priorityMetaByValue[row.priority]?.label ||
                    $t('CRM.GENERAL.EMPTY_VALUE')
                  }}
                </span>
              </span>
            </template>

            <template #cell-assignee="{ row }">
              <span class="text-sm text-n-slate-12">
                {{
                  assigneeNameById[row.assigneeId] ||
                  $t('CRM.GENERAL.EMPTY_VALUE')
                }}
              </span>
            </template>

            <template #cell-dueAt="{ row }">
              <span class="text-sm text-n-slate-12">
                {{ formatDate(row.dueAt) }}
              </span>
            </template>

            <template #cell-actions="{ row }">
              <div class="flex justify-end gap-1">
                <Button
                  size="sm"
                  color="slate"
                  variant="ghost"
                  icon="i-lucide-pen-line"
                  @click="openEditDrawer(row)"
                />
                <Button
                  v-if="canManageTasks"
                  size="sm"
                  color="slate"
                  variant="ghost"
                  :icon="
                    row.archivedAt
                      ? 'i-lucide-archive-restore'
                      : 'i-lucide-archive'
                  "
                  @click="toggleArchived(row)"
                />
              </div>
            </template>
          </SchedulingRecordTable>

          <PaginationFooter
            v-if="shouldShowListPagination"
            class="!border-t !border-n-weak !bg-transparent before:!hidden"
            :current-page="listCurrentPage"
            :total-items="filteredListTasks.length"
            :items-per-page="LIST_PAGE_SIZE"
            @update:current-page="listCurrentPage = $event"
          />
        </div>

        <CrmTaskCalendar
          v-else-if="currentPresentation === 'calendar'"
          class="min-h-0 flex-1"
          :anchor-date="calendarAnchorDate"
          :assignee-names="assigneeNameById"
          :can-manage="canManageTasks"
          :deal-names="dealNameById"
          :tasks="tasks"
          :view="currentCalendarView"
          :status-names="statusNameById"
          @create-task="openCalendarCreateDrawer"
          @move-task="updateTaskCalendarRange"
          @resize-task="updateTaskCalendarRange"
          @select-task="openEditDrawer"
        />

        <CrmTaskBoard
          v-else
          class="min-h-0 flex-1"
          :assignees="assigneeOptions"
          :can-manage="canManageTasks"
          :deal-names="dealNameById"
          :statuses="referencesStore.taskStatuses"
          :tasks="tasks"
          @change-assignee="handleTaskAssigneeChange"
          @change-status="handleTaskStatusChange"
          @create-task="handleBoardCreateTask"
          @select-task="openEditDrawer"
        />
      </div>
    </div>

    <SchedulingDrawer
      v-model="drawerOpen"
      width="sm"
      :title="
        selectedTask ? $t('CRM.TASKS.EDIT_TITLE') : $t('CRM.TASKS.CREATE_TITLE')
      "
      :description="$t('CRM.TASKS.DRAWER_DESCRIPTION')"
      :confirm-label="
        selectedTask ? $t('CRM.GENERAL.SAVE') : $t('CRM.GENERAL.CREATE')
      "
      :is-loading="ui.isSaving"
      :disable-confirm="!form.title.trim() || !form.statusId"
      @close="closeDrawer"
      @confirm="saveTask"
    >
      <div class="grid gap-4">
        <div
          v-if="form.originatingConversationId"
          class="rounded-2xl bg-n-alpha-black2 px-4 py-3 outline outline-1 outline-n-weak"
        >
          <p class="mb-1 text-sm font-medium text-n-slate-12">
            {{ $t('CRM.GENERAL.LINKED_CONVERSATION') }}
          </p>
          <p class="mb-0 text-sm text-n-slate-11">
            {{
              [
                $t('CRM.TIMELINE.CONVERSATION', {
                  id:
                    form.originatingConversationDisplayId ||
                    form.originatingConversationId,
                }),
                $t('CRM.GENERAL.CONVERSATION_SOURCE'),
              ].join(' · ')
            }}
          </p>
        </div>

        <SchedulingFormFieldGroup :framed="false">
          <div class="grid gap-4 md:grid-cols-2">
            <Input
              :label="$t('CRM.TASKS.FORM.TITLE')"
              :model-value="form.title"
              @update:model-value="form.title = $event"
            />
            <SchedulingSelectField
              :label="$t('CRM.TASKS.FORM.STATUS')"
              :model-value="form.statusId"
              :options="taskStatusOptions"
              @update:model-value="form.statusId = $event"
            />
            <SchedulingSelectField
              :label="$t('CRM.TASKS.FORM.ASSIGNEE')"
              :model-value="form.assigneeId"
              :options="assigneeOptions"
              @update:model-value="form.assigneeId = $event"
            />
            <SchedulingSelectField
              :label="$t('CRM.TASKS.FORM.TEAM')"
              :model-value="form.teamId"
              :options="teamOptions"
              @update:model-value="form.teamId = $event"
            />
            <SchedulingSelectField
              :label="$t('CRM.TASKS.FORM.DEAL')"
              :model-value="form.dealId"
              :options="dealOptions"
              @update:model-value="form.dealId = $event"
            />
            <SchedulingSelectField
              :label="$t('CRM.TASKS.FORM.PRIORITY')"
              :model-value="form.priority"
              :options="priorityOptions"
              @update:model-value="form.priority = $event"
            />
            <SchedulingDateTimeField
              :label="$t('CRM.TASKS.FORM.START_AT')"
              :model-value="form.startAt"
              type="datetime"
              @update:model-value="form.startAt = $event"
            />
            <SchedulingDateTimeField
              :label="$t('CRM.TASKS.FORM.DUE_AT')"
              :model-value="form.dueAt"
              type="datetime"
              @update:model-value="form.dueAt = $event"
            />
            <TextArea
              class="md:col-span-2"
              :label="$t('CRM.TASKS.FORM.DESCRIPTION')"
              :model-value="form.description"
              auto-height
              @update:model-value="form.description = $event"
            />
          </div>
        </SchedulingFormFieldGroup>

        <CrmCustomFieldsSection
          :definitions="applicableTaskFieldDefinitions"
          :framed="false"
          :model-value="form.customAttributes"
          :title="$t('CRM.CUSTOM_FIELDS.TITLE')"
          :description="$t('CRM.CUSTOM_FIELDS.DESCRIPTION')"
          @update:model-value="form.customAttributes = $event"
        />

        <SchedulingFormFieldGroup
          v-if="selectedTask"
          :framed="false"
          :title="$t('CRM.TIMELINE.TITLE')"
          :description="$t('CRM.TIMELINE.DESCRIPTION')"
        >
          <CrmTimelineFeed
            :items="timelineItems"
            :is-loading="ui.isTimelineLoading"
            :is-saving-comment="ui.isSavingComment"
            :can-manage-comments="canManageTasks"
            :empty-message="$t('CRM.TIMELINE.EMPTY')"
            @create-comment="saveComment"
            @delete-comment="deleteComment"
          />
        </SchedulingFormFieldGroup>
      </div>

      <template v-if="selectedTask && canManageTasks" #footer>
        <div class="flex items-center justify-between gap-3">
          <Button
            size="sm"
            color="slate"
            variant="faded"
            :label="$t('SCHEDULING.GENERAL.CANCEL')"
            @click="closeDrawer"
          />
          <div class="flex items-center gap-2">
            <Button
              size="sm"
              color="slate"
              variant="outline"
              :label="
                selectedTask.archivedAt
                  ? $t('CRM.GENERAL.UNARCHIVE')
                  : $t('CRM.GENERAL.ARCHIVE')
              "
              @click="toggleArchived(selectedTask)"
            />
            <Button
              size="sm"
              :is-loading="ui.isSaving"
              :disabled="!form.title.trim() || !form.statusId"
              :label="$t('CRM.GENERAL.SAVE')"
              @click="saveTask"
            />
          </div>
        </div>
      </template>
    </SchedulingDrawer>

    <Dialog
      ref="filterDialogRef"
      width="xl"
      :title="$t('CRM.FILTERS.TITLE')"
      :description="$t('CRM.FILTERS.DESCRIPTION')"
      :confirm-button-label="$t('CRM.FILTERS.APPLY')"
      @confirm="applyFilters"
    >
      <div class="grid gap-4 md:grid-cols-2">
        <SchedulingSelectField
          :label="$t('CRM.TASKS.FORM.STATUS')"
          :model-value="filterDraft.statusId"
          :options="taskStatusOptions"
          :placeholder="$t('CRM.TASKS.FORM.STATUS')"
          @update:model-value="filterDraft.statusId = $event"
        />

        <SchedulingSelectField
          :label="$t('CRM.TASKS.FORM.ASSIGNEE')"
          :model-value="filterDraft.assigneeId"
          :options="assigneeOptions"
          :placeholder="$t('CRM.TASKS.FORM.ASSIGNEE')"
          @update:model-value="filterDraft.assigneeId = $event"
        />

        <SchedulingSelectField
          :label="$t('CRM.TASKS.FORM.PRIORITY')"
          :model-value="filterDraft.priority"
          :options="priorityOptions"
          :placeholder="$t('CRM.TASKS.FORM.PRIORITY')"
          @update:model-value="filterDraft.priority = $event"
        />

        <SchedulingSelectField
          :label="$t('CRM.TASKS.FORM.TEAM')"
          :model-value="filterDraft.teamId"
          :options="teamOptions"
          :placeholder="$t('CRM.TASKS.FORM.TEAM')"
          @update:model-value="filterDraft.teamId = $event"
        />

        <div class="flex items-center gap-3 pt-6">
          <Checkbox
            :model-value="filterDraft.archived"
            @update:model-value="filterDraft.archived = $event"
          />
          <span class="text-sm text-n-slate-12">
            {{ $t('CRM.FILTERS.INCLUDE_ARCHIVED') }}
          </span>
        </div>
      </div>
    </Dialog>
  </section>
</template>

<style scoped>
.crm-task-list-table :deep(.grid.border-b) {
  @apply bg-n-surface-1/70;
  padding-top: 0.625rem;
  padding-bottom: 0.625rem;
}

.crm-task-list-table :deep(.divide-y > .grid) {
  gap: 0.5rem;
  padding-top: 0.5rem;
  padding-bottom: 0.5rem;
}
</style>
