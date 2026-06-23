<script setup>
import { computed, onMounted, reactive, ref, watch } from 'vue';
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
import Spinner from 'dashboard/components-next/spinner/Spinner.vue';
import TextArea from 'dashboard/components-next/textarea/TextArea.vue';
import CrmTaskAssigneeMenu from 'dashboard/components-next/CRM/CrmTaskAssigneeMenu.vue';
import CrmCustomFieldsSummary from 'dashboard/components-next/CRM/CrmCustomFieldsSummary.vue';
import CrmCustomFieldsSection from 'dashboard/components-next/CRM/CrmCustomFieldsSection.vue';
import CrmTaskBoard from 'dashboard/components-next/CRM/CrmTaskBoard.vue';
import CrmTaskCalendar from 'dashboard/components-next/CRM/CrmTaskCalendar.vue';
import CrmTaskPriorityMenu from 'dashboard/components-next/CRM/CrmTaskPriorityMenu.vue';
import CrmTaskStatusMenu from 'dashboard/components-next/CRM/CrmTaskStatusMenu.vue';
import CrmTimelineFeed from 'dashboard/components-next/CRM/CrmTimelineFeed.vue';
import PaginationFooter from 'dashboard/components-next/pagination/PaginationFooter.vue';
import SchedulingDateTimeField from 'dashboard/components-next/Scheduling/SchedulingDateTimeField.vue';
import SchedulingDrawer from 'dashboard/components-next/Scheduling/SchedulingDrawer.vue';
import SchedulingCustomFieldAdvancedFilter from 'dashboard/components-next/Scheduling/SchedulingCustomFieldAdvancedFilter.vue';
import SchedulingEmptyState from 'dashboard/components-next/Scheduling/SchedulingEmptyState.vue';
import SchedulingErrorState from 'dashboard/components-next/Scheduling/SchedulingErrorState.vue';
import SchedulingFormFieldGroup from 'dashboard/components-next/Scheduling/SchedulingFormFieldGroup.vue';
import SchedulingMultiSelectFilter from 'dashboard/components-next/Scheduling/SchedulingMultiSelectFilter.vue';
import SchedulingPageHeader from 'dashboard/components-next/Scheduling/SchedulingPageHeader.vue';
import SchedulingRecordTable from 'dashboard/components-next/Scheduling/SchedulingRecordTable.vue';
import SchedulingSelectField from 'dashboard/components-next/Scheduling/SchedulingSelectField.vue';
import SchedulingToolbar from 'dashboard/components-next/Scheduling/SchedulingToolbar.vue';
import SchedulingViewSwitcher from 'dashboard/components-next/Scheduling/SchedulingViewSwitcher.vue';
import SelectMenu from 'dashboard/components-next/selectmenu/SelectMenu.vue';
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
} from 'dashboard/stores/crm/customFieldDefaults';
import {
  buildAdvancedCustomFieldOperatorOptions,
  buildCustomFieldFilterOptions,
  buildCustomFieldFilterSummary,
  isAdvancedFilterableCustomFieldDefinition,
  isDiscreteFilterableCustomFieldDefinition,
  isFilterableCustomFieldDefinition,
  normalizeCustomFieldFilters,
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
import { DEFAULT_TASK_STATUS_COLOR } from 'dashboard/stores/crm/taskStatusColors';

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
const currentPresentation = ref('list');
const currentTaskScope = ref('mine');
const currentCalendarView = ref('week');
const calendarAnchorDate = ref(new Date());
const drawerOpen = ref(false);
const filterDialogRef = ref(null);
const listCurrentPage = ref(1);
const selectedTask = ref(null);
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

const filters = reactive({
  archived: false,
  assigneeId: '',
  dealId: '',
  priority: '',
  statusId: '',
  teamId: '',
});
const filterDraft = reactive({
  archived: false,
  assigneeId: '',
  dealId: '',
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
  isLoading: true,
  isSaving: false,
  isSavingComment: false,
  isTimelineLoading: false,
});
const taskUiActionQueryInFlight = ref(false);

const accountId = useMapGetter('getCurrentAccountId');
const agents = useMapGetter('agents/getAgents');
const currentUser = useMapGetter('getCurrentUser');
const teams = useMapGetter('teams/getTeams');

const canManageTasks = computed(() =>
  checkPermissions(CRM_TASK_MANAGE_PERMISSIONS)
);
const canAccessTaskSettings = computed(() =>
  checkPermissions([
    'administrator',
    'crm_settings_view',
    'crm_settings_manage',
  ])
);
const canViewTasks = computed(() =>
  checkPermissions(CRM_TASK_VIEW_PERMISSIONS)
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

const effectiveTaskAssigneeId = computed(() =>
  currentTaskScope.value === 'mine' ? currentUserId.value : filters.assigneeId
);

const localeCode = computed(
  () => locale.value?.replace(/_/g, '-') || undefined
);

const taskFieldDefinitions = computed(
  () => referencesStore.taskFieldDefinitions
);

const applicableTaskFieldDefinitions = computed(() => {
  const context = form.dealId ? 'deal_task' : 'standalone_task';

  return taskFieldDefinitions.value.filter(definition => {
    const contexts = definition.rules?.contexts || [];
    return contexts.length === 0 || contexts.includes(context);
  });
});

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

const priorityLabelByValue = computed(() =>
  Object.entries(priorityMetaByValue.value).reduce((result, [value, meta]) => {
    result[value] = meta.label;
    return result;
  }, {})
);

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

const taskScopeOptions = computed(() => [
  { id: 'crm-tasks-scope-mine', label: t('CRM.TASKS.SCOPE.MY'), value: 'mine' },
  { id: 'crm-tasks-scope-all', label: t('CRM.TASKS.SCOPE.ALL'), value: 'all' },
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
    label: t('CRM.TASKS.BOARD.SORT.OPTIONS.PRIORITY'),
    value: 'priority',
  },
  {
    label: t('CRM.TASKS.BOARD.SORT.OPTIONS.TITLE'),
    value: 'title',
  },
]);

const boardSortDirectionOptions = computed(() => [
  {
    label: t('CRM.TASKS.BOARD.SORT.DIRECTIONS.ASC'),
    value: 'asc',
  },
  {
    label: t('CRM.TASKS.BOARD.SORT.DIRECTIONS.DESC'),
    value: 'desc',
  },
]);

const selectedBoardSortLabel = computed(
  () =>
    boardSortOptions.value.find(option => option.value === boardSort.key)
      ?.label || t('CRM.TASKS.BOARD.SORT.LABEL')
);

const boardSortDirectionLabels = computed(() => ({
  asc:
    boardSortDirectionOptions.value.find(option => option.value === 'asc')
      ?.label || '',
  desc:
    boardSortDirectionOptions.value.find(option => option.value === 'desc')
      ?.label || '',
}));

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
    width: '2.4fr',
    sortable: true,
    defaultSortDirection: 'asc',
  },
  {
    key: 'status',
    label: t('CRM.TASKS.TABLE.STATUS'),
    width: '1fr',
    sortable: true,
    defaultSortDirection: 'asc',
  },
  {
    key: 'priority',
    label: t('CRM.TASKS.FORM.PRIORITY'),
    width: '0.95fr',
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
    if (!search) {
      return true;
    }

    return [
      task.title,
      task.description,
      `#${task.id}`,
      dealNameById.value[task.dealId],
      assigneeNameById.value[task.assigneeId],
      ...searchableTaskCustomFieldTerms(task),
    ].some(value => normalizeFilterText(value).includes(search));
  });
});

const resolveTaskSortValue = computed(() =>
  createTaskListSortValueResolver({
    assigneeNameById: assigneeNameById.value,
    priorityLabelByValue: priorityLabelByValue.value,
    statusNameById: statusNameById.value,
  })
);

const prioritySortRank = {
  none: 0,
  low: 1,
  medium: 2,
  high: 3,
  urgent: 4,
};

const resolveTaskBoardSortValue = (task, key) => {
  switch (key) {
    case 'createdAt':
      return task.createdAt ? new Date(task.createdAt).getTime() : null;
    case 'dueAt':
      return task.dueAt ? new Date(task.dueAt).getTime() : null;
    case 'position':
      return Number(task.position ?? Number.MAX_SAFE_INTEGER);
    case 'priority':
      return prioritySortRank[task.priority] ?? -1;
    case 'startAt':
      return task.startAt ? new Date(task.startAt).getTime() : null;
    case 'title':
      return normalizeFilterText(task.title);
    case 'updatedAt':
      return task.updatedAt ? new Date(task.updatedAt).getTime() : null;
    default:
      return null;
  }
};

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
  currentPresentation: 'list',
  currentTaskScope: 'mine',
  filters: {
    archived: false,
    assigneeId: '',
    dealId: '',
    priority: '',
    statusId: '',
    teamId: '',
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

  if (!['mine', 'all'].includes(next.currentTaskScope)) {
    next.currentTaskScope = defaults.currentTaskScope;
  }

  if (!['day', 'week', 'month'].includes(next.currentCalendarView)) {
    next.currentCalendarView = defaults.currentCalendarView;
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
  currentTaskScope.value = preferences.currentTaskScope;
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
      currentTaskScope: currentTaskScope.value,
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

  Object.assign(form, {
    assigneeId: currentUserId.value,
    customAttributes: buildDefaultCustomAttributes(
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
  'dealId',
  'description',
  'dueAt',
  'originatingConversationId',
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
  pendingCreateCustomFieldDefaultsHydration.value = true;
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
  pendingCreateCustomFieldDefaultsHydration.value = false;
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
  pendingCreateCustomFieldDefaultsHydration.value = false;
  drawerOpen.value = false;
  selectedTask.value = null;
  timelineItems.value = [];
  resetForm();
};

const closeTaskTitleEditor = () => {
  editingTaskTitleId.value = null;
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
  form.startAt = task.startAt ? task.startAt.slice(0, 16) : '';
  form.dueAt = task.dueAt ? task.dueAt.slice(0, 16) : '';
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
  if (!canManageTasks.value) return;

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
      assignee_id: effectiveTaskAssigneeId.value || undefined,
      custom_attribute_filters: customFieldFilters.value,
      deal_id: filters.dealId || undefined,
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

  if (!canManageTasks.value) {
    await clearTaskPrefillQuery();
    return;
  }

  await openCreateDrawer({
    assigneeId: numericQueryValue('assigneeId'),
    dealId: numericQueryValue('dealId'),
    description: queryValue('description') || '',
    dueAt: queryValue('dueAt') || '',
    originatingConversationDisplayId: queryValue('conversationDisplayId')
      ? `#${queryValue('conversationDisplayId')}`
      : '',
    originatingConversationId: numericQueryValue('originatingConversationId'),
    priority: queryValue('priority') || 'medium',
    startAt: queryValue('startAt') || '',
    statusId: numericQueryValue('statusId') || form.statusId,
    teamId: numericQueryValue('teamId'),
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
  currentPresentation.value = presentation;
  await loadTasks();
};

const selectTaskScope = async scope => {
  if (currentTaskScope.value === scope) return;

  currentTaskScope.value = scope;
  listCurrentPage.value = 1;
  await loadTasks();
};

const toggleBoardSortDirection = statusId => {
  const key = String(statusId);
  boardSortDirections[key] =
    boardSortDirections[key] === 'desc' ? 'asc' : 'desc';
};

watch(
  [
    currentPresentation,
    currentTaskScope,
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
    archived: filters.archived,
    assigneeId: filters.assigneeId,
    dealId: filters.dealId,
    priority: filters.priority,
    statusId: filters.statusId,
    teamId: filters.teamId,
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
    archived: filterDraft.archived,
    assigneeId: filterDraft.assigneeId,
    dealId: filterDraft.dealId,
    priority: filterDraft.priority,
    statusId: filterDraft.statusId,
    teamId: filterDraft.teamId,
  });
  customFieldFilters.value = normalizeCustomFieldFilters(
    filterableTaskFieldDefinitions.value,
    customFieldFilterDraft.value,
    customFieldFilterLabels.value
  );
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
    if (
      !drawerOpen.value ||
      selectedTask.value ||
      !pendingCreateCustomFieldDefaultsHydration.value ||
      !definitions.length
    ) {
      return;
    }

    form.customAttributes = mergeMissingDefaultCustomAttributes(
      form.customAttributes,
      definitions
    );
    pendingCreateCustomFieldDefaultsHydration.value = false;
  },
  { immediate: true }
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

const openCreateTaskStatusSetup = () => {
  if (!canManageTasks.value) return;

  router.push({
    name: 'crm_task_settings_index',
    params: { accountId: accountId.value },
    query: {
      action: 'create-task-status',
    },
  });
};

const openTaskSettings = () => {
  if (!canAccessTaskSettings.value) return;

  router.push({
    name: 'crm_task_settings_index',
    params: { accountId: accountId.value },
  });
};

const handleBoardCreateTask = async ({ statusId }) => {
  await openCreateDrawer({
    statusId,
  });
};

const startEditingTaskTitle = task => {
  if (!canManageTasks.value) {
    openEditDrawer(task);
    return;
  }

  editingTaskTitleId.value = task.id;
  taskTitleDraft.value = task.title || '';
};

const saveTaskTitle = async task => {
  const currentTask =
    tasks.value.find(item => Number(item.id) === Number(task.id)) || task;
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
    form.title = nextTitle;
  }

  try {
    const response = await CrmTasksAPI.update(currentTask.id, {
      lock_version: currentTask.lockVersion,
      title: nextTitle,
    });
    const updatedTask = normalizePayload(response.data);
    upsertTask(updatedTask);

    if (
      selectedTask.value &&
      Number(selectedTask.value.id) === updatedTask.id
    ) {
      selectedTask.value = updatedTask;
      form.title = updatedTask.title;
    }
  } catch (error) {
    try {
      await loadTasks();
    } catch {
      // Keep the original API error as the surfaced failure.
    }

    useAlert(formatErrorMessage(error));
  } finally {
    savingTaskTitleId.value = null;
    closeTaskTitleEditor();
  }
};

const handleTaskDueAtChange = async ({ task, dueAt }) => {
  const currentTask =
    tasks.value.find(item => Number(item.id) === Number(task.id)) || task;
  const nextDueAt = dueAt || '';
  const currentDueAt = toDateTimeInputValue(currentTask.dueAt);

  if (nextDueAt === currentDueAt) {
    return;
  }

  const previousTask = { ...currentTask };
  const optimisticTask = { ...currentTask, dueAt: nextDueAt || null };
  upsertTask(optimisticTask);
  syncTaskRangeInDrawer(optimisticTask);

  try {
    const response = await CrmTasksAPI.update(currentTask.id, {
      due_at: nextDueAt || null,
      lock_version: currentTask.lockVersion,
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

const handleTaskStatusChange = async ({ task, statusId, position }) => {
  const currentTask =
    tasks.value.find(item => Number(item.id) === Number(task.id)) || task;
  const nextStatusId = Number(statusId);
  const nextPosition = Number(position);

  if (
    !nextStatusId ||
    (Number(currentTask.statusId) === nextStatusId &&
      (!nextPosition || Number(currentTask.position) === nextPosition))
  ) {
    return;
  }

  if (
    selectedTask.value &&
    Number(selectedTask.value.id) === Number(currentTask.id)
  ) {
    selectedTask.value = {
      ...selectedTask.value,
      position: nextPosition || selectedTask.value.position,
      statusId: nextStatusId,
    };
    form.statusId = nextStatusId;
  }

  try {
    const response =
      Number(currentTask.statusId) === nextStatusId
        ? await CrmTasksAPI.update(currentTask.id, {
            lock_version: currentTask.lockVersion,
            position: nextPosition || currentTask.position,
          })
        : await CrmTasksAPI.changeStatus(currentTask.id, {
            lock_version: currentTask.lockVersion,
            position: nextPosition || undefined,
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

      if (selectedTask.value) {
        selectedTask.value =
          tasks.value.find(
            item => Number(item.id) === Number(currentTask.id)
          ) || selectedTask.value;
      }
    } catch {
      // Keep the original API error as the surfaced failure.
    }

    useAlert(formatErrorMessage(error));
  }
};

const handleTaskPriorityChange = async ({ priority, task }) => {
  const currentTask =
    tasks.value.find(item => Number(item.id) === Number(task.id)) || task;
  const nextPriority = String(priority || '');

  if (!nextPriority || currentTask.priority === nextPriority) {
    return;
  }

  const optimisticTask = { ...currentTask, priority: nextPriority };
  upsertTask(optimisticTask);

  if (
    selectedTask.value &&
    Number(selectedTask.value.id) === optimisticTask.id
  ) {
    selectedTask.value = optimisticTask;
    form.priority = nextPriority;
  }

  try {
    const response = await CrmTasksAPI.update(currentTask.id, {
      lock_version: currentTask.lockVersion,
      priority: nextPriority,
    });
    const updatedTask = normalizePayload(response.data);
    upsertTask(updatedTask);

    if (
      selectedTask.value &&
      Number(selectedTask.value.id) === updatedTask.id
    ) {
      selectedTask.value = updatedTask;
      form.priority = updatedTask.priority;
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
    restoreTasksPreferences();

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
    hasRestoredPreferences.value = true;
    persistTasksPreferences();
    await loadTasks();
    await handleTaskUiActionQuery();
  } catch (error) {
    ui.error = error;
    useAlert(formatErrorMessage(error));
  }
});

watch(
  () => [
    route.query?.taskId,
    route.query?.action,
    route.query?.source,
    route.query?.title,
    route.query?.description,
    route.query?.dueAt,
    route.query?.startAt,
    route.query?.priority,
    route.query?.dealId,
    route.query?.statusId,
    route.query?.assigneeId,
    route.query?.teamId,
    route.query?.conversationDisplayId,
    route.query?.originatingConversationId,
  ],
  handleTaskUiActionQuery
);
</script>

<template>
  <section class="flex flex-1 min-h-0 flex-col overflow-hidden bg-n-slate-2">
    <SchedulingPageHeader class="!bg-n-slate-2" :title="$t('CRM.TASKS.TITLE')">
      <template #title-actions>
        <Button
          v-if="canAccessTaskSettings"
          size="sm"
          color="slate"
          variant="ghost"
          icon="i-lucide-settings-2"
          class="!size-7"
          :aria-label="$t('SIDEBAR.SETTINGS')"
          :title="$t('SIDEBAR.SETTINGS')"
          @click="openTaskSettings"
        />
      </template>
      <template #left>
        <label
          v-for="scope in taskScopeOptions"
          :key="scope.id"
          class="relative flex cursor-pointer items-center gap-1.5 rounded-full border px-2.5 py-1.5 transition-colors focus-within:outline focus-within:outline-2 focus-within:outline-n-weak focus-within:outline-offset-2"
          :class="
            currentTaskScope === scope.value
              ? 'border-n-weak bg-n-solid-1 text-n-slate-12 shadow-[0_1px_2px_rgba(15,23,42,0.04)]'
              : 'border-transparent bg-transparent text-n-slate-11 hover:bg-n-alpha-black2/60 hover:text-n-slate-12'
          "
        >
          <input
            :id="scope.id"
            class="size-3 flex-shrink-0 border-n-slate-6 text-n-slate-12 focus:ring-n-weak focus:ring-offset-0"
            type="radio"
            name="crm-tasks-scope"
            :value="scope.value"
            :checked="currentTaskScope === scope.value"
            @change="selectTaskScope(scope.value)"
          />
          <span class="text-xs font-medium leading-none">
            {{ scope.label }}
          </span>
        </label>
      </template>
      <template #actions>
        <SelectMenu
          v-if="currentPresentation === 'board'"
          icon="i-lucide-arrow-down-up"
          :model-value="boardSort.key"
          :options="boardSortOptions"
          :label="selectedBoardSortLabel"
          sub-menu-position="bottom"
          @update:model-value="boardSort.key = $event"
        />
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
              <div class="grid w-full gap-0.5">
                <span class="flex flex-wrap items-center gap-2">
                  <Input
                    v-if="
                      canManageTasks &&
                      Number(editingTaskTitleId) === Number(row.id)
                    "
                    autofocus
                    size="sm"
                    class="min-w-[14rem] flex-1"
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
                    class="min-w-0 max-w-full border-0 bg-transparent p-0 text-left"
                    @click="
                      canManageTasks
                        ? startEditingTaskTitle(row)
                        : openEditDrawer(row)
                    "
                  >
                    <span class="font-medium text-n-slate-12">
                      {{ row.title }}
                    </span>
                  </button>
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
                <CrmCustomFieldsSummary
                  :definitions="taskFieldDefinitions"
                  :values="row.customAttributes"
                />
              </div>
            </template>

            <template #cell-status="{ row }">
              <CrmTaskStatusMenu
                v-if="canManageTasks"
                borderless
                :model-value="row.statusId"
                :statuses="referencesStore.taskStatuses"
                @update:model-value="
                  handleTaskStatusChange({ task: row, statusId: $event })
                "
              />
              <span
                v-else
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
              <CrmTaskPriorityMenu
                v-if="canManageTasks"
                :model-value="row.priority"
                :options="priorityOptions"
                @update:model-value="
                  handleTaskPriorityChange({ task: row, priority: $event })
                "
              />
              <span
                v-else
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
              <CrmTaskAssigneeMenu
                v-if="canManageTasks"
                :assignees="assigneeOptions"
                :model-value="row.assigneeId"
                @update:model-value="
                  handleTaskAssigneeChange({ task: row, assigneeId: $event })
                "
              />
              <span v-else class="text-sm text-n-slate-12">
                {{
                  assigneeNameById[row.assigneeId] ||
                  $t('CRM.GENERAL.EMPTY_VALUE')
                }}
              </span>
            </template>

            <template #cell-dueAt="{ row }">
              <SchedulingDateTimeField
                v-if="canManageTasks"
                class="!w-auto"
                type="datetime"
                :display-label="formatDate(row.dueAt)"
                :model-value="toDateTimeInputValue(row.dueAt)"
                hide-icon
                input-class="!h-auto !w-auto !justify-start !gap-1 !rounded-none !bg-transparent !px-0 !py-0 !text-sm !font-normal !text-n-slate-12 !outline-transparent hover:!outline-transparent focus-visible:!outline-transparent data-[state=open]:!outline-transparent"
                time-picker-variant="field"
                @update:model-value="
                  handleTaskDueAtChange({ task: row, dueAt: $event })
                "
              />
              <span v-else class="text-sm text-n-slate-12">
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
          :field-definitions="taskFieldDefinitions"
          :show-sort-toggle="boardSort.key !== MANUAL_BOARD_SORT_KEY"
          :statuses="referencesStore.taskStatuses"
          :sort-direction-labels="boardSortDirectionLabels"
          :sort-directions="boardSortDirections"
          :sort-key="boardSort.key"
          :sort-value-resolver="resolveTaskBoardSortValue"
          :tasks="tasks"
          @change-assignee="handleTaskAssigneeChange"
          @change-status="handleTaskStatusChange"
          @create-task="handleBoardCreateTask"
          @select-task="openEditDrawer"
          @toggle-sort-direction="toggleBoardSortDirection"
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
          :label="$t('CRM.TASKS.FORM.DEAL')"
          :model-value="filterDraft.dealId"
          :options="dealOptions"
          :placeholder="$t('CRM.TASKS.FORM.DEAL')"
          @update:model-value="filterDraft.dealId = $event"
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
