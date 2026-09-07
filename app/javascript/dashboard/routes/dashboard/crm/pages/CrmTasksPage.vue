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
import { useLocalStorage } from '@vueuse/core';
import { useI18n } from 'vue-i18n';
import { useRoute, useRouter } from 'vue-router';

import CrmDealsAPI from 'dashboard/api/crm/deals';
import CrmTasksAPI from 'dashboard/api/crm/tasks';
import { useAlert } from 'dashboard/composables';
import { useMapGetter, useStore } from 'dashboard/composables/store';
import { usePolicy } from 'dashboard/composables/usePolicy';
import {
  CRM_TASK_MANAGE_PERMISSIONS,
  CRM_TASK_VIEW_PERMISSIONS,
} from 'dashboard/constants/permissions';
import Button from 'dashboard/components-next/button/Button.vue';
import Checkbox from 'dashboard/components-next/checkbox/Checkbox.vue';
import Dialog from 'dashboard/components-next/dialog/Dialog.vue';
import Icon from 'dashboard/components-next/icon/Icon.vue';
import Input from 'dashboard/components-next/input/Input.vue';
import Switch from 'dashboard/components-next/switch/Switch.vue';
import TextArea from 'dashboard/components-next/textarea/TextArea.vue';
import CrmCustomFieldsSummary from 'dashboard/components-next/CRM/CrmCustomFieldsSummary.vue';
import CrmPageSkeleton from 'dashboard/components-next/CRM/CrmPageSkeleton.vue';
import CrmCustomFieldsSection from 'dashboard/components-next/CRM/CrmCustomFieldsSection.vue';
import CrmTaskBoard from 'dashboard/components-next/CRM/CrmTaskBoard.vue';
import { buildTaskTypeResolver } from 'dashboard/components-next/CRM/taskTypeMetadata';
import CrmTaskCalendar from 'dashboard/components-next/CRM/CrmTaskCalendar.vue';
import CrmTaskCancelDialog from 'dashboard/components-next/CRM/CrmTaskCancelDialog.vue';
import CrmTaskCompletionDialog from 'dashboard/components-next/CRM/CrmTaskCompletionDialog.vue';
import { taskMatchesStateFilter } from 'dashboard/components-next/CRM/taskCompletion';
import CrmTimelineFeed from 'dashboard/components-next/CRM/CrmTimelineFeed.vue';
import PaginationFooter from 'dashboard/components-next/pagination/PaginationFooter.vue';
import SchedulingDateTimeField from 'dashboard/components-next/Scheduling/SchedulingDateTimeField.vue';
import SchedulingDrawer from 'dashboard/components-next/Scheduling/SchedulingDrawer.vue';
import SchedulingCustomFieldAdvancedFilter from 'dashboard/components-next/Scheduling/SchedulingCustomFieldAdvancedFilter.vue';
import SchedulingEmptyState from 'dashboard/components-next/Scheduling/SchedulingEmptyState.vue';
import SchedulingEntityDateRangeFilter from 'dashboard/components-next/Scheduling/SchedulingEntityDateRangeFilter.vue';
import SchedulingErrorState from 'dashboard/components-next/Scheduling/SchedulingErrorState.vue';
import SchedulingFormFieldGroup from 'dashboard/components-next/Scheduling/SchedulingFormFieldGroup.vue';
import SchedulingMultiSelectFilter from 'dashboard/components-next/Scheduling/SchedulingMultiSelectFilter.vue';
import SchedulingPageHeader from 'dashboard/components-next/Scheduling/SchedulingPageHeader.vue';
import SchedulingRecordTable from 'dashboard/components-next/Scheduling/SchedulingRecordTable.vue';
import SchedulingSelectField from 'dashboard/components-next/Scheduling/SchedulingSelectField.vue';
import SchedulingViewSwitcher from 'dashboard/components-next/Scheduling/SchedulingViewSwitcher.vue';
import DateTimePicker from 'dashboard/components/ui/DateTimePicker.vue';

import {
  buildCalendarRange,
  formatCalendarTitle,
  shiftAnchorDate,
  toDateTimeInputValue,
} from 'dashboard/routes/dashboard/scheduling/helpers';
import { useCrmReferencesStore } from 'dashboard/stores/crm/references';
import {
  buildDefaultCustomAttributes,
  mergeMissingDefaultCustomAttributes,
  reconcileCustomAttributesForDefinitions,
} from 'dashboard/stores/crm/customFieldDefaults';
import {
  buildAdvancedCustomFieldOperatorOptions,
  buildCustomFieldFilterOptions,
  buildCustomFieldFilterSummary,
  isAdvancedFilterableCustomFieldDefinition,
  isDiscreteFilterableCustomFieldDefinition,
  isFilterableCustomFieldDefinition,
  normalizeCustomFieldFilters,
  recordMatchesCustomFieldFilters,
} from 'dashboard/stores/crm/customFieldFilters';
import { resolveCustomFieldEntries } from 'dashboard/stores/crm/customFieldFormatter';
import {
  compactPayload,
  formatCrmErrorMessage,
  normalizePayload,
} from 'dashboard/stores/crm/shared';
import {
  createTaskListSortValueResolver,
  sortListRecords,
} from 'dashboard/routes/dashboard/crm/listSort';
import {
  taskDeadlineForBucket,
  taskDueDate,
} from 'dashboard/routes/dashboard/crm/taskTimeBuckets';
import {
  assertTaskEditCurrent,
  buildTaskFormSavePayload,
  cloneTaskDraft,
  rememberTaskSnapshot,
} from 'dashboard/routes/dashboard/crm/taskLifecyclePayload';
import { BUS_EVENTS } from 'shared/constants/busEvents';
import { emitter } from 'shared/helpers/mitt';

const referencesStore = useCrmReferencesStore();
const store = useStore();
const route = useRoute();
const router = useRouter();
const { checkPermissions } = usePolicy();
const { locale, t } = useI18n();

const TASKS_PREFERENCES_STORAGE_KEY = 'crm-tasks-page-preferences';
const MANUAL_BOARD_SORT_KEY = 'position';

const tasks = ref([]);
const dealOptions = ref([]);
const currentPresentation = ref('board');
const currentCalendarView = ref('week');
const calendarAnchorDate = ref(new Date());
const drawerOpen = ref(false);
const filterDialogRef = ref(null);
const completionDialogRef = ref(null);
const cancelDialogRef = ref(null);
const listCurrentPage = ref(1);
const selectedTask = ref(null);
const taskEditSnapshot = ref(null);
const taskTitleEditSnapshot = ref(null);
const timelineItems = ref([]);
const pendingCreateCustomFieldDefaultsHydration = ref(false);
const editingTaskTitleId = ref(null);
const taskTitleDraft = ref('');
const savingTaskTitleId = ref(null);
const customFieldFilters = ref({});
const customFieldFilterDraft = ref({});
const listSort = ref({
  direction: '',
  key: '',
});
const boardSort = reactive({
  key: MANUAL_BOARD_SORT_KEY,
});
const boardSortDirections = reactive({});
const hasRestoredPreferences = ref(false);
const persistedPreferencesByAccount = useLocalStorage(
  TASKS_PREFERENCES_STORAGE_KEY,
  {}
);

const LIST_PAGE_SIZE = 25;
const LEGACY_TASK_ACTIVITY_TYPES = [
  'task',
  'call',
  'meeting',
  'message',
  'touch',
];

const filters = reactive({
  activityType: '',
  archived: false,
  assigneeId: '',
  dateRange: { from: '', to: '', type: '' },
  dealId: '',
  outcome: '',
  taskState: 'active',
});
const filterDraft = reactive({
  activityType: '',
  archived: false,
  assigneeId: '',
  dateRange: { from: '', to: '', type: '' },
  dealId: '',
  outcome: '',
  taskState: 'active',
});
const listQuickFilters = reactive({
  q: '',
});

const form = reactive({
  activityType: 'task',
  allDay: false,
  assigneeId: '',
  contextKind: 'personal',
  customAttributes: {},
  dealId: '',
  description: '',
  dueAt: '',
  externalRef: '',
  originatingConversationDisplayId: '',
  originatingConversationId: '',
  outcome: '',
  outcomeNote: '',
  priority: 'medium',
  startAt: '',
  statusId: '',
  title: '',
});

const ui = reactive({
  error: null,
  isLoading: true,
  isSaving: false,
  isSavingComment: false,
  isTimelineLoading: false,
});
const taskUiActionQueryInFlight = ref(false);
const taskLoadGeneration = ref(0);
let taskRealtimeSequence = 0;
const pendingTaskRealtimeUpdates = new Map();

const accountId = useMapGetter('getCurrentAccountId');
const agents = useMapGetter('agents/getAgents');
const currentUser = useMapGetter('getCurrentUser');

const canManageTasks = computed(() =>
  checkPermissions(CRM_TASK_MANAGE_PERMISSIONS)
);

const canViewTasks = computed(() =>
  checkPermissions(CRM_TASK_VIEW_PERMISSIONS)
);
const doneStatus = computed(() =>
  referencesStore.taskStatuses.find(status => status.category === 'done')
);
const isTaskFormDisabled = computed(
  () =>
    !form.title.trim() ||
    !form.statusId ||
    !form.contextKind ||
    (form.contextKind === 'sales' && !form.dealId)
);

const shouldRenderBoard = computed(() => currentPresentation.value === 'board');

const assigneeOptions = computed(() =>
  agents.value.map(agent => ({
    label: agent.name || agent.email,
    thumbnail: {
      name: agent.name || agent.email,
    },
    value: agent.id,
  }))
);

const taskContextOptions = computed(() => [
  {
    label: t('CRM.TASKS.CONTEXT_KIND.personal'),
    value: 'personal',
  },
  {
    label: t('CRM.TASKS.CONTEXT_KIND.sales'),
    value: 'sales',
  },
]);

const currentUserId = computed(() => {
  const userId = Number(currentUser.value?.id);
  return Number.isFinite(userId) && userId > 0 ? userId : '';
});

const localeCode = computed(
  () => locale.value?.replace(/_/g, '-') || undefined
);

const taskFieldDefinitions = computed(
  () => referencesStore.taskFieldDefinitions
);

const taskFieldDefinitionsForContext = contextKind => {
  const context = contextKind === 'sales' ? 'deal_task' : 'standalone_task';

  return taskFieldDefinitions.value.filter(definition => {
    const contexts = definition.rules?.contexts || [];
    return contexts.length === 0 || contexts.includes(context);
  });
};

const applicableTaskFieldDefinitions = computed(() =>
  taskFieldDefinitionsForContext(form.contextKind)
);

const taskCustomAttributesForContext = (customAttributes, contextKind) => {
  const draft = cloneTaskDraft(customAttributes || {});
  if (!taskFieldDefinitions.value.length) return draft;

  return reconcileCustomAttributesForDefinitions(
    draft,
    taskFieldDefinitionsForContext(contextKind)
  );
};

const customFieldFilterLabels = computed(() => ({
  noLabel: t('CHOICE_TOGGLE.NO'),
  operators: {
    after: t('SCHEDULING.CUSTOM_FIELD_FILTERS.OPERATORS.AFTER'),
    before: t('SCHEDULING.CUSTOM_FIELD_FILTERS.OPERATORS.BEFORE'),
    contains: t('SCHEDULING.CUSTOM_FIELD_FILTERS.OPERATORS.CONTAINS'),
    equals: t('SCHEDULING.CUSTOM_FIELD_FILTERS.OPERATORS.EQUALS'),
    greater_than: t('SCHEDULING.CUSTOM_FIELD_FILTERS.OPERATORS.GREATER_THAN'),
    is_not_present: t(
      'SCHEDULING.CUSTOM_FIELD_FILTERS.OPERATORS.IS_NOT_PRESENT'
    ),
    is_present: t('SCHEDULING.CUSTOM_FIELD_FILTERS.OPERATORS.IS_PRESENT'),
    less_than: t('SCHEDULING.CUSTOM_FIELD_FILTERS.OPERATORS.LESS_THAN'),
    on: t('SCHEDULING.CUSTOM_FIELD_FILTERS.OPERATORS.ON'),
  },
  yesLabel: t('CHOICE_TOGGLE.YES'),
}));

const filterableTaskFieldDefinitions = computed(() =>
  taskFieldDefinitions.value.filter(isFilterableCustomFieldDefinition)
);
const discreteTaskFieldDefinitions = computed(() =>
  filterableTaskFieldDefinitions.value.filter(
    isDiscreteFilterableCustomFieldDefinition
  )
);
const advancedTaskFieldDefinitions = computed(() =>
  filterableTaskFieldDefinitions.value.filter(
    isAdvancedFilterableCustomFieldDefinition
  )
);

const statusNameById = computed(() =>
  referencesStore.taskStatuses.reduce((result, status) => {
    result[status.id] = status.name;
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

const legacyActivityTypeMetaByValue = computed(() => ({
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

const availableTaskTypes = computed(() => {
  const configured = referencesStore.taskTypes.filter(
    taskType => taskType.active !== false || taskType.code === form.activityType
  );
  if (configured.length) return configured;

  return LEGACY_TASK_ACTIVITY_TYPES.map((code, index) => ({
    active: true,
    code,
    icon: legacyActivityTypeMetaByValue.value[code]?.icon,
    id: null,
    name: legacyActivityTypeMetaByValue.value[code]?.label || code,
    outcomes: [],
    position: index + 1,
  }));
});

const taskTypeResolver = computed(() =>
  buildTaskTypeResolver(referencesStore.taskTypes, t)
);

const taskTypeByCode = computed(() =>
  referencesStore.taskTypes.reduce((result, taskType) => {
    result[taskType.code] = taskType;
    return result;
  }, {})
);

const activityTypeOptions = computed(() =>
  availableTaskTypes.value.map(taskType => ({
    icon:
      taskType.icon || legacyActivityTypeMetaByValue.value[taskType.code]?.icon,
    label: taskType.name,
    value: taskType.code,
  }))
);

const activityTypeLabelByValue = computed(() =>
  availableTaskTypes.value.reduce((result, taskType) => {
    result[taskType.code] = taskType.name;
    return result;
  }, {})
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

const buildOutcomeOptions = (activityType, currentOutcome = '') => {
  const configuredOutcomes = taskTypeByCode.value[activityType]?.outcomes || [];
  const options = configuredOutcomes
    .filter(
      outcome => outcome.active !== false || outcome.code === currentOutcome
    )
    .map(outcome => ({ label: outcome.name, value: outcome.code }));

  if (
    currentOutcome &&
    !options.some(option => option.value === currentOutcome)
  ) {
    options.push({
      label: outcomeLabelByValue.value[currentOutcome] || currentOutcome,
      value: currentOutcome,
    });
  }

  return options;
};

const filterOutcomeOptions = computed(() =>
  buildOutcomeOptions(filterDraft.activityType, filterDraft.outcome)
);
const taskStateOptions = computed(() => [
  { label: t('CRM.TASKS.STATE_FILTER.active'), value: 'active' },
  { label: t('CRM.TASKS.STATE_FILTER.completed'), value: 'completed' },
  { label: t('CRM.TASKS.STATE_FILTER.cancelled'), value: 'cancelled' },
  { label: t('CRM.TASKS.STATE_FILTER.all'), value: 'all' },
]);

const normalizeActivityType = value => {
  if (availableTaskTypes.value.some(taskType => taskType.code === value))
    return value;

  return (
    availableTaskTypes.value.find(taskType => taskType.default)?.code ||
    availableTaskTypes.value[0]?.code ||
    'task'
  );
};

const updateFormActivityType = value => {
  form.activityType = normalizeActivityType(value);
};

const hasListSearchQuery = computed(() => listQuickFilters.q.trim().length > 0);

const viewOptions = computed(() => [
  {
    icon: 'i-lucide-columns-3',
    label: t('CRM.VIEWS.BOARD'),
    value: 'board',
  },
  {
    icon: 'i-lucide-list',
    label: t('CRM.VIEWS.LIST'),
    value: 'list',
  },
]);

const boardSortOptions = computed(() => [
  {
    label: t('CRM.TASKS.BOARD.SORT.OPTIONS.NONE'),
    value: MANUAL_BOARD_SORT_KEY,
  },
  {
    label: t('CRM.TASKS.BOARD.SORT.OPTIONS.DUE_AT'),
    value: 'dueAt',
  },
  {
    label: t('CRM.TASKS.BOARD.SORT.OPTIONS.START_AT'),
    value: 'startAt',
  },
  {
    label: t('CRM.TASKS.BOARD.SORT.OPTIONS.UPDATED_AT'),
    value: 'updatedAt',
  },
  {
    label: t('CRM.TASKS.BOARD.SORT.OPTIONS.CREATED_AT'),
    value: 'createdAt',
  },
  {
    label: t('CRM.TASKS.TABLE.ACTIVITY_TYPE'),
    value: 'activityType',
  },
  {
    label: t('CRM.TASKS.BOARD.SORT.OPTIONS.PRIORITY'),
    value: 'priority',
  },
  {
    label: t('CRM.TASKS.BOARD.SORT.OPTIONS.TITLE'),
    value: 'title',
  },
]);

const calendarViewOptions = computed(() => [
  {
    icon: 'i-lucide-calendar-days',
    label: t('SCHEDULING.VIEWS.DAY'),
    value: 'day',
  },
  {
    icon: 'i-lucide-calendar-range',
    label: t('SCHEDULING.VIEWS.WEEK'),
    value: 'week',
  },
  {
    icon: 'i-lucide-calendar-fold',
    label: t('SCHEDULING.VIEWS.MONTH'),
    value: 'month',
  },
]);

const calendarLabel = computed(() =>
  formatCalendarTitle(
    currentCalendarView.value,
    calendarAnchorDate.value,
    locale.value
  )
);

const tableColumns = computed(() => [
  {
    key: 'id',
    label: t('CRM.GENERAL.ID'),
    width: '72px',
    sortable: true,
    defaultSortDirection: 'asc',
  },
  {
    key: 'title',
    label: t('CRM.TASKS.TABLE.TITLE'),
    width: '2.1fr',
    sortable: true,
    defaultSortDirection: 'asc',
  },
  {
    key: 'activityType',
    label: t('CRM.TASKS.TABLE.ACTIVITY_TYPE'),
    width: '1fr',
    sortable: true,
    defaultSortDirection: 'asc',
  },

  {
    key: 'assignee',
    label: t('CRM.TASKS.TABLE.ASSIGNEE'),
    width: '1fr',
    sortable: true,
    defaultSortDirection: 'asc',
  },
  {
    key: 'dueAt',
    label: t('CRM.TASKS.TABLE.DUE_AT'),
    width: '1fr',
    sortable: true,
    defaultSortDirection: 'desc',
  },
  { key: 'actions', label: '', width: '112px', align: 'end' },
]);

const normalizeFilterText = value =>
  String(value || '')
    .trim()
    .toLowerCase();

const isTaskOverdue = task => {
  if (task.archivedAt || task.completedAt) return false;

  const dueDate = taskDueDate(task);
  if (!dueDate) return false;
  if (!task.allDay) return dueDate < new Date();

  const today = new Date();
  today.setHours(0, 0, 0, 0);
  return dueDate < today;
};

const taskCustomFieldEntries = task =>
  resolveCustomFieldEntries(
    taskFieldDefinitions.value,
    task?.customAttributes,
    {
      locale: localeCode.value,
      noLabel: t('CHOICE_TOGGLE.NO'),
      yesLabel: t('CHOICE_TOGGLE.YES'),
    }
  );

const searchableTaskCustomFieldTerms = task =>
  taskCustomFieldEntries(task).flatMap(entry => [
    entry.label,
    entry.displayValue,
  ]);

const filteredListTasks = computed(() => {
  const search = normalizeFilterText(listQuickFilters.q);

  return tasks.value.filter(task => {
    if (!taskMatchesStateFilter(task, filters.taskState)) return false;

    if (!search) {
      return true;
    }

    return [
      task.title,
      task.description,
      task.outcomeNote,
      activityTypeLabelByValue.value[task.activityType || 'task'],
      outcomeLabelByValue.value[task.outcome],
      `#${task.id}`,
      dealNameById.value[task.dealId],
      assigneeNameById.value[task.assigneeId],
      ...searchableTaskCustomFieldTerms(task),
    ].some(value => normalizeFilterText(value).includes(search));
  });
});

const resolveTaskSortValue = computed(() =>
  createTaskListSortValueResolver({
    activityTypeLabelByValue: activityTypeLabelByValue.value,
    assigneeNameById: assigneeNameById.value,
    statusNameById: statusNameById.value,
  })
);

const sortedListTasks = computed(() =>
  sortListRecords(
    filteredListTasks.value,
    listSort.value,
    resolveTaskSortValue.value
  )
);

const defaultTasksPreferences = () => ({
  boardSort: {
    key: MANUAL_BOARD_SORT_KEY,
  },
  boardSortDirections: {},
  currentCalendarView: 'week',
  currentPresentation: 'board',
  filters: {
    activityType: '',
    archived: false,
    assigneeId: '',
    dateRange: { from: '', to: '', type: '' },
    dealId: '',
    outcome: '',
    taskState: 'active',
  },
  listQuickFilters: {
    q: '',
  },
  listSort: {
    direction: '',
    key: '',
  },
});

const accountPreferenceKey = computed(() =>
  String(accountId.value || 'default')
);

const sanitizeTasksPreferences = preferences => {
  const defaults = defaultTasksPreferences();
  const next = {
    ...defaults,
    ...preferences,
    boardSort: {
      ...defaults.boardSort,
      ...(preferences?.boardSort || {}),
    },
    filters: {
      ...defaults.filters,
      ...(preferences?.filters || {}),
      dateRange: {
        ...defaults.filters.dateRange,
        ...(preferences?.filters?.dateRange || {}),
      },
    },
    listQuickFilters: {
      ...defaults.listQuickFilters,
      ...(preferences?.listQuickFilters || {}),
    },
    listSort: {
      ...defaults.listSort,
      ...(preferences?.listSort || {}),
    },
  };

  if (!['list', 'board', 'calendar'].includes(next.currentPresentation)) {
    next.currentPresentation = defaults.currentPresentation;
  }

  if (!['day', 'week', 'month'].includes(next.currentCalendarView)) {
    next.currentCalendarView = defaults.currentCalendarView;
  }

  if (
    !['active', 'completed', 'cancelled', 'all'].includes(
      next.filters.taskState
    )
  ) {
    next.filters.taskState = defaults.filters.taskState;
  }

  if (
    !boardSortOptions.value.some(option => option.value === next.boardSort.key)
  ) {
    next.boardSort.key = defaults.boardSort.key;
  }

  next.boardSortDirections = Object.entries(
    preferences?.boardSortDirections || {}
  ).reduce((result, [key, value]) => {
    result[key] = value === 'desc' ? 'desc' : 'asc';
    return result;
  }, {});

  return next;
};

const restoreTasksPreferences = () => {
  const stored =
    persistedPreferencesByAccount.value?.[accountPreferenceKey.value] || {};
  const preferences = sanitizeTasksPreferences(stored);

  currentPresentation.value = preferences.currentPresentation;
  currentCalendarView.value = preferences.currentCalendarView;
  listSort.value = { ...preferences.listSort };
  boardSort.key = preferences.boardSort.key;
  Object.keys(boardSortDirections).forEach(key => {
    delete boardSortDirections[key];
  });
  Object.assign(boardSortDirections, preferences.boardSortDirections);
  Object.assign(filters, preferences.filters);
  listQuickFilters.q = preferences.listQuickFilters.q;
};

const persistTasksPreferences = () => {
  if (!hasRestoredPreferences.value) return;

  persistedPreferencesByAccount.value = {
    ...(persistedPreferencesByAccount.value || {}),
    [accountPreferenceKey.value]: sanitizeTasksPreferences({
      boardSort: { ...boardSort },
      boardSortDirections: { ...boardSortDirections },
      currentCalendarView: currentCalendarView.value,
      currentPresentation: currentPresentation.value,
      filters: { ...filters },
      listQuickFilters: { ...listQuickFilters },
      listSort: { ...listSort.value },
    }),
  };
};

const paginatedListTasks = computed(() => {
  const startIndex = (listCurrentPage.value - 1) * LIST_PAGE_SIZE;
  return sortedListTasks.value.slice(startIndex, startIndex + LIST_PAGE_SIZE);
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
  () => sortedListTasks.value.length > LIST_PAGE_SIZE
);

const taskListRowClass = row => [
  row.archivedAt ? 'opacity-75' : '',
  stripedTaskRowIds.value.has(Number(row.id)) ? 'bg-n-surface-1/70' : '',
];

const handleListSortChange = sortState => {
  listCurrentPage.value = 1;
  listSort.value = sortState;
};

const resetForm = () => {
  const defaultStatus =
    referencesStore.taskStatuses.find(status => status.default) ||
    referencesStore.taskStatuses[0];
  const defaultTaskType =
    referencesStore.taskTypes.find(
      taskType => taskType.default && taskType.active
    ) || referencesStore.taskTypes.find(taskType => taskType.active);

  Object.assign(form, {
    activityType: defaultTaskType?.code || 'task',
    allDay: false,
    assigneeId: currentUserId.value,
    contextKind: 'personal',
    customAttributes: buildDefaultCustomAttributes(
      taskFieldDefinitionsForContext('personal')
    ),
    dealId: '',
    description: '',
    dueAt: '',
    externalRef: '',
    originatingConversationDisplayId: '',
    originatingConversationId: '',
    outcome: '',
    outcomeNote: '',
    priority: 'medium',
    startAt: '',
    statusId: defaultStatus?.id || '',
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
  'activityType',
  'assigneeId',
  'contactName',
  'conversationDisplayId',
  'contextKind',
  'dealId',
  'description',
  'dueAt',
  'originatingConversationId',
  'outcome',
  'outcomeNote',
  'priority',
  'source',
  'startAt',
  'statusId',
  'taskId',
  'teamId',
  'title',
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

let dealOptionsLoadGeneration = 0;
let timelineLoadGeneration = 0;
let isComponentUnmounted = false;

const resetTimeline = () => {
  timelineLoadGeneration += 1;
  timelineItems.value = [];
  ui.isTimelineLoading = false;
};

const loadDealOptions = async () => {
  if (isComponentUnmounted) return;
  dealOptionsLoadGeneration += 1;
  const generation = dealOptionsLoadGeneration;
  const requestAccountId = accountId.value;
  const isCurrent = () =>
    generation === dealOptionsLoadGeneration &&
    requestAccountId === accountId.value;

  try {
    const { data } = await CrmDealsAPI.get({
      archived: false,
      page: 1,
      per_page: 100,
    });
    if (!isCurrent()) return;
    dealOptions.value = normalizePayload(data).map(deal => ({
      label: deal.title,
      value: deal.id,
    }));
  } catch (error) {
    if (isCurrent()) throw error;
  }
};

const loadTimeline = async taskId => {
  if (isComponentUnmounted) return;
  timelineLoadGeneration += 1;
  const generation = timelineLoadGeneration;
  const requestAccountId = accountId.value;
  const isCurrent = () =>
    generation === timelineLoadGeneration &&
    requestAccountId === accountId.value &&
    drawerOpen.value &&
    Number(selectedTask.value?.id) === Number(taskId);
  if (!isCurrent()) return;
  ui.isTimelineLoading = true;

  try {
    const { data } = await CrmTasksAPI.timeline(taskId, { limit: 50 });
    if (isCurrent()) timelineItems.value = normalizePayload(data);
  } catch (error) {
    if (isCurrent()) throw error;
  } finally {
    if (isCurrent()) ui.isTimelineLoading = false;
  }
};

const openTaskSettings = () => {
  router.push({
    name: 'crm_task_settings_index',
    params: { accountId: accountId.value },
  });
};

const openCreateDrawer = async prefill => {
  selectedTask.value = null;
  taskEditSnapshot.value = null;
  pendingCreateCustomFieldDefaultsHydration.value = true;
  resetForm();
  resetTimeline();
  drawerOpen.value = true;

  if (prefill) {
    Object.assign(form, prefill);
    if (prefill.dealId && !prefill.contextKind) form.contextKind = 'sales';
  }
  await loadDealOptions();
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

const taskDueInputValue = task => {
  if (task.allDay) return task.dueOn || '';
  if (!task.dueAt) return '';

  return task.dueAt.slice(0, 16);
};

const buildPayload = () => {
  const taskType = taskTypeByCode.value[form.activityType];
  const payload = compactPayload({
    activity_type: form.activityType || 'task',
    task_type_id: taskType?.id ? Number(taskType.id) : undefined,
    all_day: form.allDay,
    assignee_id: form.assigneeId ? Number(form.assigneeId) : undefined,
    context_kind: form.contextKind,
    custom_attributes: form.customAttributes,
    deal_id: form.dealId ? Number(form.dealId) : null,
    description: form.description || undefined,
    due_at: form.allDay ? undefined : form.dueAt || undefined,
    due_on: form.allDay ? form.dueAt || undefined : undefined,
    external_ref: form.externalRef || undefined,
    lock_version: selectedTask.value?.lockVersion,
    originating_conversation_id: form.originatingConversationId
      ? Number(form.originatingConversationId)
      : undefined,
    start_at: form.startAt || undefined,
    status_id: form.statusId ? Number(form.statusId) : undefined,
    title: form.title.trim(),
  });

  if (form.allDay) {
    payload.due_at = null;
    payload.start_at = null;
  } else {
    payload.due_on = null;
  }

  if (selectedTask.value) {
    payload.deal_id = form.dealId ? Number(form.dealId) : null;
    payload.description = form.description || null;
    payload.external_ref = form.externalRef || null;
    payload.originating_conversation_id = form.originatingConversationId
      ? Number(form.originatingConversationId)
      : null;
  }

  return payload;
};

const openEditDrawer = async task => {
  pendingCreateCustomFieldDefaultsHydration.value = false;
  selectedTask.value = task;
  resetTimeline();
  const contextKind = task.contextKind || (task.dealId ? 'sales' : 'personal');
  Object.assign(form, {
    activityType: normalizeActivityType(task.activityType || 'task'),
    allDay: Boolean(task.allDay),
    assigneeId: task.assigneeId ?? '',
    contextKind,
    customAttributes: taskCustomAttributesForContext(
      task.customAttributes,
      contextKind
    ),
    dealId: task.dealId ?? '',
    description: task.description || '',
    dueAt: taskDueInputValue(task),
    externalRef: task.externalRef || '',
    originatingConversationDisplayId: task.originatingConversationId
      ? `#${task.originatingConversationId}`
      : '',
    originatingConversationId: task.originatingConversationId ?? '',
    outcome: task.outcome || '',
    outcomeNote: task.outcomeNote || '',
    priority: task.priority || 'medium',
    startAt: task.startAt ? task.startAt.slice(0, 16) : '',
    statusId: task.statusId,
    title: task.title,
  });
  taskEditSnapshot.value = cloneTaskDraft({ task, payload: buildPayload() });
  drawerOpen.value = true;
  await Promise.all([loadDealOptions(), loadTimeline(task.id)]);
};

const closeDrawer = () => {
  pendingCreateCustomFieldDefaultsHydration.value = false;
  drawerOpen.value = false;
  selectedTask.value = null;
  taskEditSnapshot.value = null;
  resetTimeline();
  resetForm();
};

const closeTaskTitleEditor = () => {
  editingTaskTitleId.value = null;
  taskTitleEditSnapshot.value = null;
  taskTitleDraft.value = '';
};

const syncTaskRangeInDrawer = task => {
  if (
    !selectedTask.value ||
    Number(selectedTask.value.id) !== Number(task.id)
  ) {
    return;
  }

  selectedTask.value = task;
  form.allDay = Boolean(task.allDay);
  form.startAt = task.startAt ? task.startAt.slice(0, 16) : '';
  form.dueAt = taskDueInputValue(task);
};

const upsertTask = task => {
  if (rememberTaskSnapshot(pendingTaskRealtimeUpdates, task) !== task) return;
  const existingIndex = tasks.value.findIndex(item => item.id === task.id);

  if (existingIndex === -1) {
    tasks.value = [task, ...tasks.value];
    return;
  }

  const nextTasks = [...tasks.value];
  nextTasks.splice(existingIndex, 1, task);
  tasks.value = nextTasks;
};

const removeTask = taskId => {
  tasks.value = tasks.value.filter(task => Number(task.id) !== Number(taskId));
};

const taskMatchesRealtimeFilters = task => {
  if (!taskMatchesStateFilter(task, filters.taskState)) return false;
  if (filters.activityType && task.activityType !== filters.activityType) {
    return false;
  }
  if (Boolean(task.archivedAt) !== Boolean(filters.archived)) return false;
  if (
    filters.assigneeId &&
    Number(task.assigneeId) !== Number(filters.assigneeId)
  ) {
    return false;
  }
  if (filters.dealId && Number(task.dealId) !== Number(filters.dealId)) {
    return false;
  }
  if (filters.outcome && task.outcome !== filters.outcome) return false;

  const dueDate = taskDueDate(task);
  if (filters.dateRange.from) {
    const dueFrom = new Date(filters.dateRange.from);
    if (!dueDate || dueDate < dueFrom) return false;
  }
  if (filters.dateRange.to) {
    const dueTo = new Date(filters.dateRange.to);
    dueTo.setHours(23, 59, 59, 999);
    if (!dueDate || dueDate > dueTo) return false;
  }

  return recordMatchesCustomFieldFilters(
    task,
    taskFieldDefinitions.value,
    customFieldFilters.value
  );
};

const applyTaskRealtimeState = task => {
  if (rememberTaskSnapshot(pendingTaskRealtimeUpdates, task) !== task) return;
  if (taskMatchesRealtimeFilters(task)) {
    upsertTask(task);
  } else {
    removeTask(task.id);
  }
};

const runTaskMutation = async (request, expectedTask) => {
  const accountAtStart = accountId.value;
  if (expectedTask) {
    assertTaskEditCurrent(
      expectedTask,
      pendingTaskRealtimeUpdates.get(Number(expectedTask.id))?.task ||
        expectedTask
    );
  }
  const response = await request();
  if (accountAtStart !== accountId.value) assertTaskEditCurrent(null, null);
  const responseTask = normalizePayload(response.data);
  taskRealtimeSequence += 1;
  const newest = rememberTaskSnapshot(
    pendingTaskRealtimeUpdates,
    responseTask,
    taskRealtimeSequence
  );
  applyTaskRealtimeState(newest);
  if (Number(selectedTask.value?.id) === Number(newest.id))
    selectedTask.value = newest;
  if (expectedTask) assertTaskEditCurrent(responseTask, newest);
  return newest;
};

const handleCrmTaskRealtimeEvent = payload => {
  if (
    Number(payload?.account_id) !== Number(accountId.value) ||
    !payload?.task
  ) {
    return;
  }

  taskRealtimeSequence += 1;
  const task = rememberTaskSnapshot(
    pendingTaskRealtimeUpdates,
    normalizePayload({ payload: payload.task }),
    taskRealtimeSequence
  );
  applyTaskRealtimeState(task);

  if (Number(selectedTask.value?.id) === Number(task.id)) {
    selectedTask.value = task;
  }
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

const updateAllDay = enabled => {
  form.allDay = enabled;

  if (enabled) {
    const dueDate = form.dueAt ? new Date(form.dueAt) : new Date();
    form.dueAt = format(dueDate, 'yyyy-MM-dd');
    form.startAt = '';
    return;
  }

  if (form.dueAt) form.dueAt = `${form.dueAt.slice(0, 10)}T12:00`;
};

const saveTask = async () => {
  if (!canManageTasks.value || ui.isSaving) return;

  ui.isSaving = true;

  try {
    const payload = buildPayload();
    const draft = cloneTaskDraft(form);
    let task;

    if (selectedTask.value) {
      const currentTask = taskEditSnapshot.value?.task;
      const savePayload = buildTaskFormSavePayload({
        snapshot: taskEditSnapshot.value,
        currentTask: selectedTask.value,
        requested: payload,
        form: draft,
      });
      task = await runTaskMutation(() =>
        CrmTasksAPI.saveForm(currentTask.id, savePayload)
      );
    } else {
      task = await runTaskMutation(() => CrmTasksAPI.create(payload));
    }

    applyTaskRealtimeState(task);
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

const openTaskCompletionDialog = task => {
  if (!canManageTasks.value || !doneStatus.value || task?.archivedAt) return;

  completionDialogRef.value?.open(task);
};

const saveTaskCompletion = async ({ task, note, taskOutcomeId }) => {
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
    applyTaskRealtimeState(updatedTask);
    completionDialogRef.value?.close();
    closeDrawer();
    useAlert(t('CRM.TASKS.SUCCESS_UPDATED'));
  } catch (error) {
    useAlert(formatErrorMessage(error));
  } finally {
    ui.isSaving = false;
  }
};

const openTaskCancelDialog = task => {
  if (
    !canManageTasks.value ||
    task?.archivedAt ||
    task?.completedAt ||
    task?.cancelledAt
  ) {
    return;
  }

  cancelDialogRef.value?.open(task);
};

const saveTaskCancellation = async ({ task, reason }) => {
  const currentTask =
    tasks.value.find(item => Number(item.id) === Number(task.id)) || task;
  ui.isSaving = true;

  try {
    const updatedTask = await runTaskMutation(() =>
      CrmTasksAPI.cancel(currentTask.id, {
        cancellation_reason: reason,
        idempotency_key: crypto.randomUUID(),
        lock_version: currentTask.lockVersion,
      })
    );
    applyTaskRealtimeState(updatedTask);
    cancelDialogRef.value?.close();
    closeDrawer();
    useAlert(t('CRM.TASKS.SUCCESS_UPDATED'));
  } catch (error) {
    useAlert(formatErrorMessage(error));
  } finally {
    ui.isSaving = false;
  }
};

const reopenTask = async task => {
  if (!canManageTasks.value || (!task?.completedAt && !task?.cancelledAt)) {
    return;
  }

  ui.isSaving = true;
  try {
    const updatedTask = await runTaskMutation(() =>
      CrmTasksAPI.reopen(task.id, {
        idempotency_key: crypto.randomUUID(),
        lock_version: task.lockVersion,
      })
    );
    applyTaskRealtimeState(updatedTask);
    selectedTask.value = updatedTask;
    useAlert(t('CRM.TASKS.LIFECYCLE.REOPENED'));
  } catch (error) {
    useAlert(formatErrorMessage(error));
  } finally {
    ui.isSaving = false;
  }
};

const toggleArchived = async task => {
  try {
    const updatedTask = await runTaskMutation(() =>
      task.archivedAt
        ? CrmTasksAPI.unarchive(task.id, { lock_version: task.lockVersion })
        : CrmTasksAPI.archive(task.id, { lock_version: task.lockVersion })
    );
    applyTaskRealtimeState(updatedTask);
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
  taskLoadGeneration.value += 1;
  const loadGeneration = taskLoadGeneration.value;
  const realtimeSequenceAtStart = taskRealtimeSequence;
  ui.isLoading = true;
  ui.error = null;

  try {
    const query = compactPayload({
      activity_type: filters.activityType || undefined,
      archived: filters.archived,
      assignee_id: filters.assigneeId || undefined,
      custom_attribute_filters: customFieldFilters.value,
      deal_id: filters.dealId || undefined,
      due_from: filters.dateRange.from || undefined,
      due_to: filters.dateRange.to || undefined,
      outcome: filters.outcome || undefined,
    });

    if (currentPresentation.value === 'calendar') {
      const { from, to } = buildCalendarRange(
        currentCalendarView.value,
        calendarAnchorDate.value
      );
      const calendarTo = new Date(to.getTime() + 1);
      const selectedFrom = query.due_from ? new Date(query.due_from) : null;
      const selectedTo = query.due_to ? new Date(query.due_to) : null;

      query.due_from = new Date(
        Math.max(from.getTime(), selectedFrom?.getTime() || from.getTime())
      ).toISOString();
      query.due_to = new Date(
        Math.min(
          calendarTo.getTime(),
          selectedTo?.getTime() || calendarTo.getTime()
        )
      ).toISOString();
    }

    const { data } = await CrmTasksAPI.get(query);
    if (loadGeneration !== taskLoadGeneration.value) return;

    tasks.value = normalizePayload(data)
      .map(task => rememberTaskSnapshot(pendingTaskRealtimeUpdates, task))
      .filter(taskMatchesRealtimeFilters);
    pendingTaskRealtimeUpdates.forEach(update => {
      if (update.sequence <= realtimeSequenceAtStart) return;

      applyTaskRealtimeState(update.task);
    });
    syncSelectedTask(tasks.value);
  } catch (error) {
    if (loadGeneration !== taskLoadGeneration.value) return;
    ui.error = error;
  } finally {
    if (loadGeneration === taskLoadGeneration.value) ui.isLoading = false;
  }
};

const updateTaskDeadlineFromBoard = async ({ bucket, task }) => {
  if (!canManageTasks.value || !task) return;

  const deadline = taskDeadlineForBucket(bucket);

  try {
    const updatedTask = await runTaskMutation(() =>
      CrmTasksAPI.reschedule(task.id, {
        all_day: deadline.allDay,
        due_at: deadline.dueAt,
        due_on: deadline.dueOn,
        idempotency_key: crypto.randomUUID(),
        lock_version: task.lockVersion,
        start_at: deadline.startAt,
      })
    );
    applyTaskRealtimeState(updatedTask);
    syncTaskRangeInDrawer(updatedTask);
    useAlert(t('CRM.TASKS.SUCCESS_UPDATED'));
  } catch (error) {
    useAlert(formatErrorMessage(error));
    await loadTasks();
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

  if (!canManageTasks.value) {
    await clearTaskPrefillQuery();
    return;
  }

  await openCreateDrawer({
    activityType: normalizeActivityType(queryValue('activityType') || 'task'),
    assigneeId: numericQueryValue('assigneeId'),
    contextKind:
      queryValue('contextKind') ||
      (numericQueryValue('dealId') ? 'sales' : 'personal'),
    dealId: numericQueryValue('dealId'),
    description: queryValue('description') || '',
    dueAt: queryValue('dueAt') || '',
    originatingConversationDisplayId: queryValue('conversationDisplayId')
      ? `#${queryValue('conversationDisplayId')}`
      : '',
    originatingConversationId: numericQueryValue('originatingConversationId'),
    outcome: queryValue('outcome') || '',
    outcomeNote: queryValue('outcomeNote') || '',
    priority: queryValue('priority') || 'medium',
    startAt: queryValue('startAt') || '',
    statusId: numericQueryValue('statusId') || form.statusId,
    title: queryValue('title') || buildPrefillTaskTitle(),
  });
  await clearTaskPrefillQuery();
};

const consumeTaskOpenQuery = async () => {
  const taskId = numericQueryValue('taskId');
  if (!taskId) return false;

  try {
    let task = tasks.value.find(record => Number(record.id) === Number(taskId));
    if (!task) {
      const { data } = await CrmTasksAPI.show(taskId);
      task = normalizePayload(data);
      upsertTask(task);
    }

    await openEditDrawer(task);
  } catch (error) {
    useAlert(formatErrorMessage(error));
  } finally {
    await clearTaskPrefillQuery();
  }

  return true;
};

const handlePresentationChange = async presentation => {
  if (currentPresentation.value === presentation) return;

  currentPresentation.value = presentation;
  await loadTasks();
};

const selectCalendarPresentation = async view => {
  if (
    currentPresentation.value === 'calendar' &&
    currentCalendarView.value === view
  ) {
    return;
  }

  currentCalendarView.value = view;
  currentPresentation.value = 'calendar';
  await loadTasks();
};

watch(
  [
    currentPresentation,
    currentCalendarView,
    listSort,
    () => ({ ...boardSort }),
    () => ({ ...boardSortDirections }),
    () => ({ ...filters }),
    () => listQuickFilters.q,
  ],
  () => {
    persistTasksPreferences();
  },
  { deep: true }
);

const syncFilterDraft = () => {
  Object.assign(filterDraft, {
    activityType: filters.activityType,
    archived: filters.archived,
    assigneeId: filters.assigneeId,
    dateRange: { ...filters.dateRange },
    dealId: filters.dealId,
    outcome: filters.outcome,
    taskState: filters.taskState,
  });
  customFieldFilterDraft.value = { ...customFieldFilters.value };
};

const openFilterDialog = () => {
  syncFilterDraft();
  filterDialogRef.value?.open();
};

const customFieldFilterOptions = definition =>
  buildCustomFieldFilterOptions(definition, customFieldFilterLabels.value);

const customFieldAdvancedOperatorOptions = definition =>
  buildAdvancedCustomFieldOperatorOptions(
    definition,
    customFieldFilterLabels.value
  );

const customFieldAdvancedFilterSummary = definition =>
  buildCustomFieldFilterSummary(
    definition,
    customFieldFilterDraft.value?.[definition.key],
    customFieldFilterLabels.value
  );

const updateTaskCustomFieldFilterDraft = (key, value) => {
  customFieldFilterDraft.value = {
    ...customFieldFilterDraft.value,
    [key]: value,
  };
};

const applyFilters = async () => {
  listCurrentPage.value = 1;
  Object.assign(filters, {
    activityType: filterDraft.activityType,
    archived: filterDraft.archived,
    assigneeId: filterDraft.assigneeId,
    dateRange: { ...filterDraft.dateRange },
    dealId: filterDraft.dealId,
    outcome: filterDraft.outcome,
    taskState: filterDraft.taskState,
  });
  customFieldFilters.value = normalizeCustomFieldFilters(
    filterableTaskFieldDefinitions.value,
    customFieldFilterDraft.value,
    customFieldFilterLabels.value
  );
  filterDialogRef.value?.close();
  await loadTasks();
};

const resetFilters = async () => {
  const defaults = defaultTasksPreferences();
  Object.assign(filters, {
    ...defaults.filters,
    dateRange: { ...defaults.filters.dateRange },
  });
  customFieldFilters.value = {};
  customFieldFilterDraft.value = {};
  listQuickFilters.q = '';
  listCurrentPage.value = 1;
  syncFilterDraft();
  filterDialogRef.value?.close();
  await loadTasks();
};

watch(
  filterableTaskFieldDefinitions,
  definitions => {
    customFieldFilters.value = normalizeCustomFieldFilters(
      definitions,
      customFieldFilters.value,
      customFieldFilterLabels.value
    );
    customFieldFilterDraft.value = normalizeCustomFieldFilters(
      definitions,
      customFieldFilterDraft.value,
      customFieldFilterLabels.value
    );
  },
  { immediate: true }
);

watch(
  applicableTaskFieldDefinitions,
  definitions => {
    if (!drawerOpen.value || !definitions.length) return;

    if (selectedTask.value) {
      form.customAttributes = reconcileCustomAttributesForDefinitions(
        form.customAttributes,
        definitions
      );
      return;
    }

    if (!pendingCreateCustomFieldDefaultsHydration.value) return;

    form.customAttributes = mergeMissingDefaultCustomAttributes(
      form.customAttributes,
      definitions
    );
    pendingCreateCustomFieldDefaultsHydration.value = false;
  },
  { immediate: true }
);

watch(
  () => form.contextKind,
  (contextKind, previousContextKind) => {
    if (
      !drawerOpen.value ||
      contextKind === previousContextKind ||
      !taskFieldDefinitions.value.length
    ) {
      return;
    }

    form.customAttributes = reconcileCustomAttributesForDefinitions(
      form.customAttributes,
      taskFieldDefinitionsForContext(contextKind)
    );
  }
);

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

const startEditingTaskTitle = task => {
  if (!canManageTasks.value) {
    openEditDrawer(task);
    return;
  }

  editingTaskTitleId.value = task.id;
  taskTitleEditSnapshot.value = cloneTaskDraft(task);
  taskTitleDraft.value = task.title || '';
};

const saveTaskTitle = async task => {
  const latestTask =
    tasks.value.find(item => Number(item.id) === Number(task.id)) || task;
  const currentTask = taskTitleEditSnapshot.value || task;
  try {
    assertTaskEditCurrent(currentTask, latestTask);
  } catch (error) {
    useAlert(formatErrorMessage(error));
    return;
  }
  const nextTitle = String(taskTitleDraft.value || '').trim();
  const currentTitle = String(currentTask.title || '').trim();

  if (!nextTitle || nextTitle === currentTitle) {
    closeTaskTitleEditor();
    return;
  }

  if (savingTaskTitleId.value === currentTask.id) {
    return;
  }

  savingTaskTitleId.value = currentTask.id;
  const optimisticTask = { ...currentTask, title: nextTitle };
  upsertTask(optimisticTask);

  if (
    selectedTask.value &&
    Number(selectedTask.value.id) === optimisticTask.id
  ) {
    selectedTask.value = optimisticTask;
  }

  try {
    const updatedTask = await runTaskMutation(
      () =>
        CrmTasksAPI.update(currentTask.id, {
          lock_version: currentTask.lockVersion,
          title: nextTitle,
        }),
      currentTask
    );
    applyTaskRealtimeState(updatedTask);

    if (
      selectedTask.value &&
      Number(selectedTask.value.id) === updatedTask.id
    ) {
      selectedTask.value = updatedTask;
    }
    closeTaskTitleEditor();
  } catch (error) {
    try {
      await loadTasks();
    } catch {
      // Keep the original API error as the surfaced failure.
    }

    useAlert(formatErrorMessage(error));
  } finally {
    savingTaskTitleId.value = null;
  }
};

const handleTaskDueAtChange = async ({ task, dueAt }) => {
  const currentTask =
    tasks.value.find(item => Number(item.id) === Number(task.id)) || task;
  const nextDueAt = dueAt || '';
  const currentDueAt = currentTask.allDay
    ? currentTask.dueOn || ''
    : toDateTimeInputValue(currentTask.dueAt);

  if (nextDueAt === currentDueAt) {
    return;
  }

  const previousTask = { ...currentTask };
  const optimisticTask = {
    ...currentTask,
    dueAt: currentTask.allDay ? null : nextDueAt || null,
    dueOn: currentTask.allDay ? nextDueAt.slice(0, 10) || null : null,
  };
  upsertTask(optimisticTask);
  syncTaskRangeInDrawer(optimisticTask);

  try {
    const updatedTask = await runTaskMutation(() =>
      CrmTasksAPI.reschedule(currentTask.id, {
        due_at: currentTask.allDay ? null : nextDueAt || null,
        due_on: currentTask.allDay ? nextDueAt.slice(0, 10) || null : null,
        idempotency_key: crypto.randomUUID(),
        lock_version: currentTask.lockVersion,
      })
    );
    applyTaskRealtimeState(updatedTask);
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

const updateTaskCalendarRange = async ({ allDay, task, startsAt, endsAt }) => {
  if (!canManageTasks.value) {
    return;
  }

  const currentTask =
    tasks.value.find(item => Number(item.id) === Number(task?.id)) || task;

  if (!currentTask?.id) {
    return;
  }

  let dueAt = endsAt;
  let dueOn = null;
  let startAt = startsAt;
  if (allDay) {
    dueOn = format(new Date(startsAt), 'yyyy-MM-dd');
    dueAt = null;
    startAt = null;
  }

  const previousTask = { ...currentTask };
  const optimisticTask = {
    ...currentTask,
    allDay: Boolean(allDay),
    dueAt,
    dueOn,
    startAt,
  };

  upsertTask(optimisticTask);
  syncTaskRangeInDrawer(optimisticTask);

  try {
    const updatedTask = await runTaskMutation(() =>
      CrmTasksAPI.reschedule(currentTask.id, {
        all_day: Boolean(allDay),
        due_at: dueAt,
        due_on: dueOn,
        idempotency_key: crypto.randomUUID(),
        lock_version: currentTask.lockVersion,
        start_at: startAt,
      })
    );
    applyTaskRealtimeState(updatedTask);
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

const handleTaskUiActionQuery = async () => {
  if (!hasRestoredPreferences.value || !canViewTasks.value) return;
  if (taskUiActionQueryInFlight.value) return;

  taskUiActionQueryInFlight.value = true;
  try {
    if (await consumeTaskOpenQuery()) return;
    await consumeTaskPrefillQuery();
  } finally {
    taskUiActionQueryInFlight.value = false;
  }
};

onMounted(async () => {
  if (!canViewTasks.value) return;

  try {
    emitter.on(BUS_EVENTS.CRM_TASK_REALTIME_EVENT, handleCrmTaskRealtimeEvent);
    restoreTasksPreferences();

    if (!agents.value.length) {
      await store.dispatch('agents/get');
    }

    await Promise.all([
      referencesStore.loadTaskStatuses(),
      referencesStore.loadTaskTypes(),
      referencesStore.loadFieldDefinitions('task'),
      loadDealOptions(),
    ]);
    resetForm();
    hasRestoredPreferences.value = true;
    persistTasksPreferences();
    await loadTasks();
    await handleTaskUiActionQuery();
  } catch (error) {
    ui.error = error;
    useAlert(formatErrorMessage(error));
  }
});

onBeforeUnmount(() => {
  emitter.off(BUS_EVENTS.CRM_TASK_REALTIME_EVENT, handleCrmTaskRealtimeEvent);
  isComponentUnmounted = true;
  dealOptionsLoadGeneration += 1;
  timelineLoadGeneration += 1;
  taskLoadGeneration.value += 1;
  pendingTaskRealtimeUpdates.clear();
});

watch(accountId, () => {
  dealOptionsLoadGeneration += 1;
  dealOptions.value = [];
  taskLoadGeneration.value += 1;
  pendingTaskRealtimeUpdates.clear();
  taskRealtimeSequence = 0;
  tasks.value = [];
  closeDrawer();
  closeTaskTitleEditor();
  if (canViewTasks.value) loadTasks();
});

watch(
  () => [
    route.query?.taskId,
    route.query?.action,
    route.query?.source,
    route.query?.title,
    route.query?.description,
    route.query?.activityType,
    route.query?.dueAt,
    route.query?.startAt,
    route.query?.priority,
    route.query?.outcome,
    route.query?.dealId,
    route.query?.statusId,
    route.query?.assigneeId,
    route.query?.conversationDisplayId,
    route.query?.originatingConversationId,
  ],
  handleTaskUiActionQuery
);
</script>

<template>
  <section class="flex flex-1 min-h-0 flex-col overflow-hidden bg-n-slate-2">
    <SchedulingPageHeader class="!bg-n-slate-2" :title="$t('CRM.TASKS.TITLE')">
      <template #left>
        <div class="flex items-center gap-2 whitespace-nowrap">
          <SchedulingViewSwitcher
            icon-only
            :model-value="currentPresentation"
            :views="viewOptions"
            @update:model-value="handlePresentationChange"
          />
          <SchedulingViewSwitcher
            :model-value="
              currentPresentation === 'calendar' ? currentCalendarView : ''
            "
            :views="calendarViewOptions"
            @update:model-value="selectCalendarPresentation"
          />
        </div>
      </template>
      <template #actions>
        <div
          v-if="currentPresentation === 'calendar'"
          class="flex items-center gap-1 whitespace-nowrap"
        >
          <Button
            size="sm"
            color="slate"
            variant="faded"
            icon="i-lucide-chevron-left"
            @click="shiftCalendar(-1)"
          />
          <Button
            size="sm"
            color="slate"
            variant="faded"
            icon="i-lucide-chevron-right"
            @click="shiftCalendar(1)"
          />
          <Button
            size="sm"
            color="slate"
            variant="outline"
            :label="$t('SCHEDULING.GENERAL.TODAY')"
            @click="jumpCalendarToToday"
          />
          <DateTimePicker
            class="!w-auto"
            type="date"
            :value="calendarAnchorDate"
            :display-label="calendarLabel"
            hide-icon
            input-class="!h-8 !w-auto !bg-n-alpha-black2 !px-3 !py-1.5 !text-sm !font-semibold !text-n-slate-12 !outline-n-weak hover:!outline-n-slate-6 focus-visible:!outline-n-brand data-[state=open]:!outline-n-brand"
            @change="selectCalendarDate"
          />
        </div>
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
          variant="ghost"
          icon="i-lucide-filter"
          class="!text-n-slate-11 hover:!text-n-slate-12"
          @click="openFilterDialog"
        />

        <Button
          v-if="canManageTasks"
          size="sm"
          color="slate"
          variant="ghost"
          icon="i-lucide-settings"
          class="!size-8 !text-n-slate-11 hover:!text-n-slate-12"
          :aria-label="$t('SIDEBAR.SETTINGS')"
          :title="$t('SIDEBAR.SETTINGS')"
          @click="openTaskSettings"
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
        <CrmPageSkeleton
          v-if="ui.isLoading"
          :presentation="currentPresentation"
        />

        <SchedulingErrorState
          v-else-if="ui.error"
          :title="$t('CRM.ERRORS.LOAD_TITLE')"
          :description="formatErrorMessage(ui.error)"
          @retry="loadTasks"
        />

        <SchedulingEmptyState
          v-else-if="tasks.length === 0 && currentPresentation === 'list'"
          icon="i-lucide-list-todo"
          title=""
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
            :sort-state="listSort"
            @sort="handleListSortChange"
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
              <div class="grid min-w-0 w-full gap-0.5">
                <span class="flex min-w-0 items-center gap-2 overflow-hidden">
                  <Input
                    v-if="
                      canManageTasks &&
                      Number(editingTaskTitleId) === Number(row.id)
                    "
                    autofocus
                    size="sm"
                    class="min-w-0 flex-1"
                    :disabled="savingTaskTitleId === row.id"
                    :model-value="taskTitleDraft"
                    custom-input-class="font-medium shadow-none !bg-n-surface-1"
                    @update:model-value="taskTitleDraft = $event"
                    @blur="saveTaskTitle(row)"
                    @enter="saveTaskTitle(row)"
                  />
                  <button
                    v-else
                    type="button"
                    class="min-w-0 flex-1 overflow-hidden border-0 bg-transparent p-0 text-left"
                    :title="row.title"
                    @click="
                      canManageTasks
                        ? startEditingTaskTitle(row)
                        : openEditDrawer(row)
                    "
                  >
                    <span class="block truncate font-medium text-n-slate-12">
                      {{ row.title }}
                    </span>
                  </button>
                  <span
                    v-if="row.dealId"
                    class="min-w-0 max-w-[40%] shrink truncate rounded-md border border-n-weak bg-n-surface-1 px-1.5 py-0.5 text-[10px] font-medium text-n-slate-11"
                    :title="dealNameById[row.dealId]"
                  >
                    {{
                      dealNameById[row.dealId] || $t('CRM.GENERAL.EMPTY_VALUE')
                    }}
                  </span>
                  <span
                    v-if="row.archivedAt"
                    class="shrink-0 rounded-md bg-n-amber-9/10 px-1.5 py-0.5 text-[10px] font-medium text-n-amber-11"
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
                <CrmCustomFieldsSummary
                  :definitions="taskFieldDefinitions"
                  :values="row.customAttributes"
                />
              </div>
            </template>

            <template #cell-activityType="{ row }">
              <div class="flex flex-wrap items-center gap-1.5">
                <span
                  class="inline-flex items-center gap-1 rounded-md border border-n-weak bg-n-surface-1 px-1.5 py-0.5 text-[10px] font-medium text-n-slate-11"
                >
                  <span
                    class="size-3"
                    :class="taskTypeResolver(row).icon"
                    aria-hidden="true"
                  />
                  {{ taskTypeResolver(row).label }}
                </span>
                <span
                  v-if="row.outcome"
                  class="rounded-md bg-n-alpha-black2 px-1.5 py-0.5 text-[10px] font-medium text-n-slate-10"
                >
                  {{ outcomeLabelByValue[row.outcome] || row.outcome }}
                </span>
              </div>
            </template>

            <template #cell-assignee="{ row }">
              <span
                class="block truncate text-sm text-n-slate-12"
                :title="assigneeNameById[row.assigneeId]"
              >
                {{
                  assigneeNameById[row.assigneeId] ||
                  $t('CRM.GENERAL.EMPTY_VALUE')
                }}
              </span>
            </template>

            <template #cell-dueAt="{ row }">
              <div class="flex flex-wrap items-center gap-2">
                <SchedulingDateTimeField
                  v-if="canManageTasks"
                  class="!w-auto"
                  :type="row.allDay ? 'date' : 'datetime'"
                  :display-label="formatDate(taskDueDate(row))"
                  :model-value="taskDueInputValue(row)"
                  hide-icon
                  input-class="!h-auto !w-auto !justify-start !gap-1 !rounded-none !bg-transparent !px-0 !py-0 !text-sm !font-normal !text-n-slate-12 !outline-transparent hover:!outline-transparent focus-visible:!outline-transparent data-[state=open]:!outline-transparent"
                  time-picker-variant="field"
                  @update:model-value="
                    handleTaskDueAtChange({ task: row, dueAt: $event })
                  "
                />
                <span v-else class="text-sm text-n-slate-12">
                  {{ formatDate(taskDueDate(row)) }}
                </span>
                <span
                  v-if="isTaskOverdue(row)"
                  class="rounded-full bg-n-ruby-9/10 px-2 py-0.5 text-[10px] font-semibold text-n-ruby-11"
                >
                  {{ $t('CRM.TASKS.BOARD.OVERDUE_BADGE') }}
                </span>
              </div>
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
            :total-items="sortedListTasks.length"
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
          :field-definitions="taskFieldDefinitions"
          :tasks="tasks"
          :view="currentCalendarView"
          @create-task="openCalendarCreateDrawer"
          @move-task="updateTaskCalendarRange"
          @resize-task="updateTaskCalendarRange"
          @select-task="openEditDrawer"
        />

        <CrmTaskBoard
          v-else
          class="min-h-0 flex-1"
          :task-type-resolver="taskTypeResolver"
          :assignees="assigneeOptions"
          :can-manage="canManageTasks"
          :deal-names="dealNameById"
          :field-definitions="taskFieldDefinitions"
          :tasks="tasks"
          @change-due-date="updateTaskDeadlineFromBoard"
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
      :disable-confirm="isTaskFormDisabled"
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
              :label="$t('CRM.TASKS.FORM.ACTIVITY_TYPE')"
              :model-value="form.activityType"
              :options="activityTypeOptions"
              @update:model-value="updateFormActivityType"
            />

            <SchedulingSelectField
              :label="$t('CRM.TASKS.FORM.ASSIGNEE')"
              :model-value="form.assigneeId"
              :options="assigneeOptions"
              @update:model-value="form.assigneeId = $event"
            />

            <SchedulingSelectField
              :label="$t('CRM.TASKS.FORM.CONTEXT_KIND')"
              :model-value="form.contextKind"
              :options="taskContextOptions"
              @update:model-value="form.contextKind = $event"
            />

            <SchedulingSelectField
              :label="$t('CRM.TASKS.FORM.DEAL')"
              :model-value="form.dealId"
              :options="dealOptions"
              @update:model-value="form.dealId = $event"
            />

            <p
              v-if="form.contextKind === 'sales' && !form.dealId"
              class="mb-0 text-xs text-n-ruby-11 md:col-span-2"
            >
              {{ $t('CRM.TASKS.FORM.SALES_DEAL_REQUIRED') }}
            </p>

            <div class="flex items-center gap-3 md:col-span-2">
              <Switch
                :model-value="form.allDay"
                @update:model-value="updateAllDay"
              />
              <span class="text-sm font-medium text-n-slate-12">
                {{ $t('CRM.TASKS.FORM.ALL_DAY') }}
              </span>
            </div>

            <SchedulingDateTimeField
              v-if="!form.allDay"
              :label="$t('CRM.TASKS.FORM.START_AT')"
              :model-value="form.startAt"
              type="datetime"
              @update:model-value="form.startAt = $event"
            />
            <SchedulingDateTimeField
              :label="$t('CRM.TASKS.FORM.DUE_AT')"
              :model-value="form.dueAt"
              :type="form.allDay ? 'date' : 'datetime'"
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
          @update:model-value="form.customAttributes = $event"
        />

        <CrmTimelineFeed
          v-if="selectedTask"
          :items="timelineItems"
          :is-loading="ui.isTimelineLoading"
          :is-saving-comment="ui.isSavingComment"
          :can-manage-comments="canManageTasks"
          :empty-message="$t('CRM.TIMELINE.EMPTY')"
          @create-comment="saveComment"
          @delete-comment="deleteComment"
        />
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
              v-if="
                doneStatus &&
                !selectedTask.archivedAt &&
                !selectedTask.cancelledAt
              "
              size="sm"
              color="teal"
              variant="faded"
              icon="i-lucide-circle-check-big"
              :label="
                selectedTask.completedAt
                  ? $t('CRM.TASKS.RESULT_DIALOG.CHANGE_ACTION')
                  : $t('CRM.TASKS.RESULT_DIALOG.ACTION')
              "
              @click="openTaskCompletionDialog(selectedTask)"
            />
            <Button
              v-if="
                !selectedTask.archivedAt &&
                !selectedTask.completedAt &&
                !selectedTask.cancelledAt
              "
              size="sm"
              color="ruby"
              variant="faded"
              icon="i-lucide-ban"
              :label="$t('CRM.TASKS.LIFECYCLE.CANCEL_ACTION')"
              @click="openTaskCancelDialog(selectedTask)"
            />
            <Button
              v-if="selectedTask.completedAt || selectedTask.cancelledAt"
              size="sm"
              color="slate"
              variant="faded"
              icon="i-lucide-rotate-ccw"
              :label="$t('CRM.TASKS.LIFECYCLE.REOPEN_ACTION')"
              @click="reopenTask(selectedTask)"
            />
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
              :disabled="isTaskFormDisabled"
              :label="$t('CRM.GENERAL.SAVE')"
              @click="saveTask"
            />
          </div>
        </div>
      </template>
    </SchedulingDrawer>

    <CrmTaskCompletionDialog
      ref="completionDialogRef"
      :is-loading="ui.isSaving"
      :task-types="referencesStore.taskTypes"
      @confirm="saveTaskCompletion"
    />

    <CrmTaskCancelDialog
      ref="cancelDialogRef"
      :is-loading="ui.isSaving"
      @confirm="saveTaskCancellation"
    />

    <Dialog
      ref="filterDialogRef"
      width="5xl"
      position="top"
      :title="$t('CRM.FILTERS.TITLE')"
      :description="$t('CRM.FILTERS.DESCRIPTION')"
      :confirm-button-label="$t('CRM.FILTERS.APPLY')"
      @confirm="applyFilters"
    >
      <div class="grid gap-4">
        <div class="w-full">
          <SchedulingEntityDateRangeFilter
            v-model="filterDraft.dateRange"
            :label="$t('CRM.FILTERS.DUE_AT_RANGE')"
          />
        </div>

        <div class="grid gap-4 md:grid-cols-3">
          <SchedulingSelectField
            :label="$t('CRM.TASKS.FORM.ACTIVITY_TYPE')"
            :model-value="filterDraft.activityType"
            :options="activityTypeOptions"
            :placeholder="$t('CRM.TASKS.FORM.ACTIVITY_TYPE')"
            @update:model-value="filterDraft.activityType = $event"
          />

          <SchedulingSelectField
            :label="$t('CRM.TASKS.FORM.OUTCOME')"
            :model-value="filterDraft.outcome"
            :options="filterOutcomeOptions"
            :placeholder="$t('CRM.TASKS.FORM.OUTCOME')"
            @update:model-value="filterDraft.outcome = $event"
          />

          <SchedulingSelectField
            :label="$t('CRM.TASKS.STATE_FILTER.LABEL')"
            :model-value="filterDraft.taskState"
            :options="taskStateOptions"
            @update:model-value="filterDraft.taskState = $event"
          />
        </div>

        <div class="grid gap-4 md:grid-cols-2">
          <SchedulingSelectField
            :label="$t('CRM.TASKS.FORM.ASSIGNEE')"
            :model-value="filterDraft.assigneeId"
            :options="assigneeOptions"
            :placeholder="$t('CRM.TASKS.FORM.ASSIGNEE')"
            @update:model-value="filterDraft.assigneeId = $event"
          />

          <SchedulingSelectField
            :label="$t('CRM.TASKS.FORM.DEAL')"
            :model-value="filterDraft.dealId"
            :options="dealOptions"
            :placeholder="$t('CRM.TASKS.FORM.DEAL')"
            @update:model-value="filterDraft.dealId = $event"
          />
        </div>

        <div class="grid gap-4 md:grid-cols-3">
          <SchedulingMultiSelectFilter
            v-for="definition in discreteTaskFieldDefinitions"
            :key="definition.key"
            :model-value="customFieldFilterDraft[definition.key] || []"
            :options="customFieldFilterOptions(definition)"
            :placeholder="definition.label"
            :show-trigger-icon="false"
            @update:model-value="
              updateTaskCustomFieldFilterDraft(definition.key, $event)
            "
          />

          <SchedulingCustomFieldAdvancedFilter
            v-for="definition in advancedTaskFieldDefinitions"
            :key="definition.key"
            :definition="definition"
            :model-value="customFieldFilterDraft[definition.key] || null"
            :operator-options="customFieldAdvancedOperatorOptions(definition)"
            :placeholder="definition.label"
            :summary-label="customFieldAdvancedFilterSummary(definition)"
            :apply-label="$t('SCHEDULING.GENERAL.APPLY')"
            :clear-label="$t('SCHEDULING.GENERAL.CLEAR')"
            :value-placeholder="$t('SCHEDULING.GENERAL.VALUE')"
            @update:model-value="
              updateTaskCustomFieldFilterDraft(definition.key, $event)
            "
          />
        </div>

        <div class="flex items-center gap-3">
          <Checkbox
            :model-value="filterDraft.archived"
            @update:model-value="filterDraft.archived = $event"
          />
          <span class="text-sm text-n-slate-12">
            {{ $t('CRM.FILTERS.INCLUDE_ARCHIVED') }}
          </span>
        </div>
      </div>
      <template #footer>
        <div class="flex w-full flex-wrap items-center justify-between gap-3">
          <Button
            type="button"
            color="slate"
            variant="ghost"
            :label="$t('CRM.FILTERS.RESET')"
            @click="resetFilters"
          />
          <div class="flex items-center gap-3">
            <Button
              type="button"
              color="slate"
              variant="faded"
              :label="$t('CRM.GENERAL.CANCEL')"
              @click="filterDialogRef?.close()"
            />
            <Button
              type="button"
              :is-loading="ui.isLoading"
              :label="$t('CRM.FILTERS.APPLY')"
              @click="applyFilters"
            />
          </div>
        </div>
      </template>
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
