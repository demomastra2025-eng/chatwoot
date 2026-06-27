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
import { useDebounceFn, useLocalStorage } from '@vueuse/core';
import { useI18n } from 'vue-i18n';
import { onBeforeRouteLeave, useRoute, useRouter } from 'vue-router';

import CompanyAPI from 'dashboard/api/companies';
import ContactAPI from 'dashboard/api/contacts';
import CrmDealsAPI from 'dashboard/api/crm/deals';
import { useAlert } from 'dashboard/composables';
import { useMapGetter, useStore } from 'dashboard/composables/store';
import { usePolicy } from 'dashboard/composables/usePolicy';
import { FEATURE_FLAGS } from 'dashboard/featureFlags';
import {
  CRM_DEAL_MANAGE_PERMISSIONS,
  CRM_DEAL_VIEW_PERMISSIONS,
  CRM_TASK_MANAGE_PERMISSIONS,
} from 'dashboard/constants/permissions';
import Button from 'dashboard/components-next/button/Button.vue';
import Checkbox from 'dashboard/components-next/checkbox/Checkbox.vue';
import Dialog from 'dashboard/components-next/dialog/Dialog.vue';
import Icon from 'dashboard/components-next/icon/Icon.vue';
import Input from 'dashboard/components-next/input/Input.vue';
import Spinner from 'dashboard/components-next/spinner/Spinner.vue';
import Switch from 'dashboard/components-next/switch/Switch.vue';
import TextArea from 'dashboard/components-next/textarea/TextArea.vue';
import CrmClosingReasonDialog from 'dashboard/components-next/CRM/CrmClosingReasonDialog.vue';
import CrmDealConversationPanel from 'dashboard/components-next/CRM/CrmDealConversationPanel.vue';
import CrmCustomFieldsSummary from 'dashboard/components-next/CRM/CrmCustomFieldsSummary.vue';
import CrmCustomFieldsSection from 'dashboard/components-next/CRM/CrmCustomFieldsSection.vue';
import CrmDealBoard from 'dashboard/components-next/CRM/CrmDealBoard.vue';
import CrmDealOwnerMenu from 'dashboard/components-next/CRM/CrmDealOwnerMenu.vue';
import CrmDealStageMenu from 'dashboard/components-next/CRM/CrmDealStageMenu.vue';
import CrmTimelineFeed from 'dashboard/components-next/CRM/CrmTimelineFeed.vue';
import PaginationFooter from 'dashboard/components-next/pagination/PaginationFooter.vue';
import SchedulingDateTimeField from 'dashboard/components-next/Scheduling/SchedulingDateTimeField.vue';
import SchedulingCurrencyAmountInput from 'dashboard/components-next/Scheduling/SchedulingCurrencyAmountInput.vue';
import SchedulingCustomFieldAdvancedFilter from 'dashboard/components-next/Scheduling/SchedulingCustomFieldAdvancedFilter.vue';
import SchedulingEmptyState from 'dashboard/components-next/Scheduling/SchedulingEmptyState.vue';
import SchedulingErrorState from 'dashboard/components-next/Scheduling/SchedulingErrorState.vue';
import SchedulingMultiSelectFilter from 'dashboard/components-next/Scheduling/SchedulingMultiSelectFilter.vue';
import SchedulingPageHeader from 'dashboard/components-next/Scheduling/SchedulingPageHeader.vue';
import SchedulingRecordTable from 'dashboard/components-next/Scheduling/SchedulingRecordTable.vue';
import SchedulingSelectField from 'dashboard/components-next/Scheduling/SchedulingSelectField.vue';
import SchedulingViewSwitcher from 'dashboard/components-next/Scheduling/SchedulingViewSwitcher.vue';
import SelectMenu from 'dashboard/components-next/selectmenu/SelectMenu.vue';
import TagMultiSelectComboBox from 'dashboard/components-next/combobox/TagMultiSelectComboBox.vue';
import CreateCompanyDialog from 'dashboard/components-next/Companies/CompanyForm/CreateCompanyDialog.vue';
import CreateNewContactDialog from 'dashboard/components-next/Contacts/ContactsForm/CreateNewContactDialog.vue';
import {
  formatDealAmount,
  majorAmountToMinor,
  resolveDealAmountMajor,
} from 'dashboard/components-next/CRM/dealAmount';
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
import { DEFAULT_STAGE_COLOR } from 'dashboard/stores/crm/stageColors';
import {
  compactPayload,
  formatCrmErrorMessage,
  normalizePayload,
} from 'dashboard/stores/crm/shared';
import {
  createDealListSortValueResolver,
  sortListRecords,
} from 'dashboard/routes/dashboard/crm/listSort';
import {
  DuplicateContactException,
  ExceptionWithMessage,
} from 'shared/helpers/CustomErrors';
import { BUS_EVENTS } from 'shared/constants/busEvents';
import { emitter } from 'shared/helpers/mitt';

const referencesStore = useCrmReferencesStore();
const store = useStore();
const route = useRoute();
const router = useRouter();
const { checkPermissions } = usePolicy();
const { locale, t } = useI18n();

const DEALS_PREFERENCES_STORAGE_KEY = 'crm-deals-page-preferences';
const MANUAL_BOARD_SORT_KEY = 'position';
const CRM_DEAL_ARCHIVE_EVENTS = new Set([
  'crm.deal.archived',
  'crm.deal.unarchived',
]);

const deals = ref([]);
const currentPresentation = ref('board');
const drawerOpen = ref(false);
const closingReasonDialogRef = ref(null);
const filterDialogRef = ref(null);
const listCurrentPage = ref(1);
const timelineItems = ref([]);
const contactOptions = ref([]);
const companyOptions = ref([]);
const createCompanyDialogRef = ref(null);
const createNewContactDialogRef = ref(null);
const selectedDeal = ref(null);
const pendingCreateCustomFieldDefaultsHydration = ref(false);
const editingDealTitleId = ref(null);
const dealTitleDraft = ref('');
const savingDealTitleId = ref(null);
const formBaselineSnapshot = ref('');
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
const showLinkedConversationPanel = ref(false);
const hasRestoredPreferences = ref(false);
const persistedPreferencesByAccount = useLocalStorage(
  DEALS_PREFERENCES_STORAGE_KEY,
  {}
);

const LIST_PAGE_SIZE = 25;

const filters = reactive({
  aiOnly: false,
  archived: false,
  companyId: '',
  contactId: '',
  ownerId: '',
  pipelineId: '',
  stageId: '',
  teamId: '',
});
const filterDraft = reactive({
  archived: false,
  companyId: '',
  contactId: '',
  ownerId: '',
  pipelineId: '',
  stageId: '',
  teamId: '',
});
const listQuickFilters = reactive({
  q: '',
});

const form = reactive({
  amount: 0,
  companyId: '',
  contactIds: [],
  closingReasons: [],
  currency: '',
  customAttributes: {},
  description: '',
  expectedCloseOn: '',
  externalRef: '',
  originatingCommunicationThreadDisplayId: '',
  originatingCommunicationThreadId: '',
  originatingConversationDisplayId: '',
  originatingConversationId: '',
  ownerId: '',
  pipelineId: '',
  primaryContactId: '',
  stageId: '',
  teamId: '',
  title: '',
  winProbability: '',
});

const ui = reactive({
  error: null,
  isLoading: true,
  isSaving: false,
  isSavingComment: false,
  isTimelineLoading: false,
});

const closeDealTitleEditor = () => {
  editingDealTitleId.value = null;
  dealTitleDraft.value = '';
};

function formatConversationDisplayLabel(value) {
  return value ? `#${value}` : '';
}

const accountId = useMapGetter('getCurrentAccountId');
const agents = useMapGetter('agents/getAgents');
const currentUser = useMapGetter('getCurrentUser');
const teams = useMapGetter('teams/getTeams');
const isFeatureEnabledonAccount = useMapGetter(
  'accounts/isFeatureEnabledonAccount'
);

const canManageDeals = computed(() =>
  checkPermissions(CRM_DEAL_MANAGE_PERMISSIONS)
);
const canManageTasks = computed(
  () =>
    isFeatureEnabledonAccount.value(accountId.value, FEATURE_FLAGS.CRM_TASKS) &&
    checkPermissions(CRM_TASK_MANAGE_PERMISSIONS)
);
const canAccessDealSettings = computed(
  () =>
    isFeatureEnabledonAccount.value(accountId.value, FEATURE_FLAGS.CRM_DEALS) &&
    checkPermissions([
      'administrator',
      'crm_settings_view',
      'crm_settings_manage',
    ])
);
const canViewDeals = computed(() =>
  checkPermissions(CRM_DEAL_VIEW_PERMISSIONS)
);
const companiesEnabled = computed(() =>
  isFeatureEnabledonAccount.value(accountId.value, FEATURE_FLAGS.COMPANIES)
);
const linkedConversationId = computed(() => {
  const conversationId = Number(form.originatingConversationId);
  return Number.isFinite(conversationId) && conversationId > 0
    ? conversationId
    : 0;
});
const linkedConversationDisplayId = computed(() =>
  String(form.originatingConversationDisplayId || '').replace(/[^\d]/g, '')
);
const linkedCommunicationThreadId = computed(() => {
  const communicationThreadId = Number(form.originatingCommunicationThreadId);
  return Number.isFinite(communicationThreadId) && communicationThreadId > 0
    ? communicationThreadId
    : 0;
});
const linkedCommunicationThreadDisplayId = computed(() =>
  String(form.originatingCommunicationThreadDisplayId || '').replace(
    /[^\d]/g,
    ''
  )
);
const canOpenLinkedConversation = computed(
  () =>
    !!linkedCommunicationThreadId.value ||
    !!linkedCommunicationThreadDisplayId.value ||
    !!linkedConversationId.value ||
    !!linkedConversationDisplayId.value
);
const archiveTooltip = computed(() =>
  selectedDeal.value?.archivedAt
    ? t('CRM.GENERAL.UNARCHIVE')
    : t('CRM.GENERAL.ARCHIVE')
);
const dealUiActionQueryInFlight = ref(false);

const activePipelines = computed(() =>
  referencesStore.pipelines.filter(pipeline => pipeline.active !== false)
);

const pipelineOptions = computed(() =>
  referencesStore.pipelines.map(pipeline => ({
    icon: 'i-lucide-funnel',
    label: pipeline.name,
    value: pipeline.id,
  }))
);

const defaultPipeline = computed(
  () =>
    activePipelines.value.find(pipeline => pipeline.default) ||
    activePipelines.value[0] ||
    null
);

const selectedPipeline = computed(
  () =>
    activePipelines.value.find(
      pipeline => Number(pipeline.id) === Number(filters.pipelineId)
    ) ||
    defaultPipeline.value ||
    null
);

const pipelineToggleItems = computed(() =>
  activePipelines.value.map(pipeline => ({
    id: `crm-deals-pipeline-${pipeline.id}`,
    label: pipeline.name,
    value: pipeline.id,
  }))
);

const hasSelectedPipeline = pipelineId =>
  pipelineToggleItems.value.some(
    item => Number(item.value) === Number(pipelineId)
  );

const resolvePipelineFilterId = pipelineId => {
  if (hasSelectedPipeline(pipelineId)) {
    return pipelineId;
  }

  return defaultPipeline.value?.id || pipelineToggleItems.value[0]?.value || '';
};

const isActivePipeline = pipelineId =>
  Number(filters.pipelineId) === Number(pipelineId);

const stageOptions = computed(() =>
  (
    referencesStore.pipelines.find(
      pipeline => Number(pipeline.id) === Number(form.pipelineId)
    )?.stages || []
  ).map(stage => ({
    label: stage.name,
    stageColor: stage.color || DEFAULT_STAGE_COLOR,
    value: stage.id,
  }))
);

const agentAvatarSrc = agent =>
  agent.thumbnail?.src ||
  (typeof agent.thumbnail === 'string' ? agent.thumbnail : '') ||
  agent.avatarUrl ||
  agent.avatar_url ||
  agent.avatar ||
  agent.imageUrl ||
  agent.image_url ||
  '';

const ownerOptions = computed(() =>
  agents.value.map(agent => ({
    label: agent.name || agent.email,
    thumbnail: {
      name: agent.name || agent.email,
      src: agentAvatarSrc(agent),
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

const shouldShowTeamField = computed(
  () => teamOptions.value.length > 0 || !!form.teamId
);

const drawerModalClass = computed(() => [
  'mx-auto flex h-full w-full overflow-hidden rounded-2xl border border-n-weak bg-n-solid-2 shadow-2xl',
  showLinkedConversationPanel.value
    ? 'max-w-[min(96rem,calc(100vw-1.5rem))] flex-col md:flex-row'
    : 'max-w-[min(30rem,calc(100vw-1.5rem))] flex-col',
]);

const filterStageOptions = computed(() => {
  const pipelineId = resolvePipelineFilterId(
    filterDraft.pipelineId || filters.pipelineId
  );
  const pipeline = activePipelines.value.find(
    item => Number(item.id) === Number(pipelineId)
  );

  return (pipeline?.stages || []).map(stage => ({
    label: stage.name,
    stageColor: stage.color || DEFAULT_STAGE_COLOR,
    value: stage.id,
  }));
});

const boardStages = computed(() => {
  const pipelines = filters.pipelineId
    ? activePipelines.value.filter(
        pipeline => Number(pipeline.id) === Number(filters.pipelineId)
      )
    : activePipelines.value;

  return pipelines.flatMap(pipeline =>
    (pipeline.stages || []).map(stage => ({
      color: stage.color,
      id: stage.id,
      label: stage.name,
      name: stage.name,
      pipelineId: pipeline.id,
    }))
  );
});

const hasBoardStages = computed(() => boardStages.value.length > 0);

const listStageOptionsForDeal = deal => {
  return (
    activePipelines.value.find(
      pipeline => Number(pipeline.id) === Number(deal.pipelineId)
    )?.stages || []
  );
};

const TERMINAL_STAGE_OUTCOMES = new Set(['won', 'lost']);
const isTerminalStage = stage =>
  TERMINAL_STAGE_OUTCOMES.has(String(stage?.outcome || '').toLowerCase());
const normalizedTextValues = values => [
  ...new Set(
    (Array.isArray(values) ? values : [values])
      .map(value => String(value || '').trim())
      .filter(Boolean)
  ),
];
const closingReasonOptionsForStage = stage =>
  normalizedTextValues(stage?.closingReasonOptions);
const transitionReasonOptionsForStage = stage =>
  normalizedTextValues(stage?.transitionReasonOptions);
const findStageById = stageId =>
  activePipelines.value
    .flatMap(pipeline => pipeline.stages || [])
    .find(stage => Number(stage.id) === Number(stageId));
const shouldPromptForClosingReasons = stage =>
  isTerminalStage(stage) && closingReasonOptionsForStage(stage).length > 0;
const shouldPromptForTransitionReason = stage =>
  !isTerminalStage(stage) && transitionReasonOptionsForStage(stage).length > 0;

const collectClosingReasonsForStage = async ({ targetStage, deal = null }) => {
  if (!targetStage) return [];
  if (!shouldPromptForClosingReasons(targetStage)) return [];

  return (
    closingReasonDialogRef.value?.open({
      currentReasons: normalizedTextValues(
        deal?.closingReasons || form.closingReasons
      ),
      kind: 'closing',
      targetStage,
    }) ?? []
  );
};

const collectTransitionReasonForStage = async ({ targetStage }) => {
  if (!targetStage) return '';
  if (!shouldPromptForTransitionReason(targetStage)) return '';

  return (
    closingReasonDialogRef.value?.open({
      kind: 'transition',
      targetStage,
    }) ?? ''
  );
};

const shouldRenderBoard = computed(
  () => currentPresentation.value === 'board' && hasBoardStages.value
);

const viewOptions = computed(() => [
  { label: t('CRM.VIEWS.BOARD'), value: 'board' },
  { label: t('CRM.VIEWS.LIST'), value: 'list' },
]);

const boardSortOptions = computed(() => [
  {
    label: t('CRM.DEALS.BOARD.SORT.OPTIONS.NONE'),
    value: MANUAL_BOARD_SORT_KEY,
  },
  {
    label: t('CRM.DEALS.BOARD.SORT.OPTIONS.EXPECTED_CLOSE_ON'),
    value: 'expectedCloseOn',
  },
  {
    label: t('CRM.DEALS.BOARD.SORT.OPTIONS.UPDATED_AT'),
    value: 'updatedAt',
  },
  {
    label: t('CRM.DEALS.BOARD.SORT.OPTIONS.CREATED_AT'),
    value: 'createdAt',
  },
  {
    label: t('CRM.DEALS.BOARD.SORT.OPTIONS.AMOUNT'),
    value: 'amount',
  },
  {
    label: t('CRM.DEALS.BOARD.SORT.OPTIONS.TITLE'),
    value: 'title',
  },
]);

const boardSortDirectionOptions = computed(() => [
  {
    label: t('CRM.DEALS.BOARD.SORT.DIRECTIONS.ASC'),
    value: 'asc',
  },
  {
    label: t('CRM.DEALS.BOARD.SORT.DIRECTIONS.DESC'),
    value: 'desc',
  },
]);

const selectedBoardSortLabel = computed(
  () =>
    boardSortOptions.value.find(option => option.value === boardSort.key)
      ?.label || t('CRM.DEALS.BOARD.SORT.LABEL')
);

const boardSortDirectionLabels = computed(() => ({
  asc:
    boardSortDirectionOptions.value.find(option => option.value === 'asc')
      ?.label || '',
  desc:
    boardSortDirectionOptions.value.find(option => option.value === 'desc')
      ?.label || '',
}));

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
    label: t('CRM.DEALS.TABLE.TITLE'),
    width: '2.4fr',
    sortable: true,
    defaultSortDirection: 'asc',
  },
  {
    key: 'stage',
    label: t('CRM.DEALS.TABLE.STAGE'),
    width: '1fr',
    sortable: true,
    defaultSortDirection: 'asc',
  },
  {
    key: 'amount',
    label: t('CRM.DEALS.TABLE.AMOUNT'),
    width: '1fr',
    align: 'end',
    sortable: true,
    defaultSortDirection: 'desc',
    headerClass: 'ltr:pr-4 rtl:pl-4',
    cellClass: 'ltr:pr-4 rtl:pl-4',
  },
  {
    key: 'owner',
    label: t('CRM.DEALS.TABLE.OWNER'),
    width: '1fr',
    sortable: true,
    defaultSortDirection: 'asc',
  },
  {
    key: 'updatedAt',
    label: t('CRM.DEALS.TABLE.UPDATED'),
    width: '0.95fr',
    sortable: true,
    defaultSortDirection: 'asc',
  },
  { key: 'actions', label: '', width: '112px', align: 'end' },
]);

const dealFieldDefinitions = computed(
  () => referencesStore.dealFieldDefinitions
);

const pipelineNameById = computed(() =>
  referencesStore.pipelines.reduce((result, pipeline) => {
    result[pipeline.id] = pipeline.name;
    return result;
  }, {})
);

const stageNameById = computed(() =>
  referencesStore.pipelines.reduce((result, pipeline) => {
    (pipeline.stages || []).forEach(stage => {
      result[stage.id] = stage.name;
    });
    return result;
  }, {})
);

const stageColorById = computed(() =>
  referencesStore.pipelines.reduce((result, pipeline) => {
    (pipeline.stages || []).forEach(stage => {
      result[stage.id] = stage.color || DEFAULT_STAGE_COLOR;
    });
    return result;
  }, {})
);

const ownerNameById = computed(() =>
  agents.value.reduce((result, agent) => {
    result[agent.id] = agent.name || agent.email;
    return result;
  }, {})
);

const localeCode = computed(
  () => locale.value?.replace(/_/g, '-') || undefined
);

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

const filterableDealFieldDefinitions = computed(() =>
  dealFieldDefinitions.value.filter(isFilterableCustomFieldDefinition)
);
const discreteDealFieldDefinitions = computed(() =>
  filterableDealFieldDefinitions.value.filter(
    isDiscreteFilterableCustomFieldDefinition
  )
);
const advancedDealFieldDefinitions = computed(() =>
  filterableDealFieldDefinitions.value.filter(
    isAdvancedFilterableCustomFieldDefinition
  )
);

const hasListSearchQuery = computed(() => listQuickFilters.q.trim().length > 0);

const normalizeFilterText = value =>
  String(value || '')
    .trim()
    .toLowerCase();

const dealCustomFieldEntries = deal =>
  resolveCustomFieldEntries(
    dealFieldDefinitions.value,
    deal?.customAttributes,
    {
      locale: localeCode.value,
      noLabel: t('CHOICE_TOGGLE.NO'),
      yesLabel: t('CHOICE_TOGGLE.YES'),
    }
  );

const searchableDealCustomFieldTerms = deal =>
  dealCustomFieldEntries(deal).flatMap(entry => [
    entry.label,
    entry.displayValue,
  ]);

const filteredListDeals = computed(() => {
  const search = normalizeFilterText(listQuickFilters.q);

  return deals.value.filter(deal => {
    if (!search) {
      return true;
    }

    return [
      deal.title,
      deal.description,
      `#${deal.id}`,
      deal.externalRef,
      deal.company?.name,
      deal.primaryContact?.name,
      pipelineNameById.value[deal.pipelineId],
      stageNameById.value[deal.stageId],
      ownerNameById.value[deal.ownerId],
      resolveDealAmountMajor(deal),
      deal.currency,
      ...searchableDealCustomFieldTerms(deal),
    ].some(value => normalizeFilterText(value).includes(search));
  });
});

const resolveDealSortValue = computed(() =>
  createDealListSortValueResolver({
    ownerNameById: ownerNameById.value,
    stageNameById: stageNameById.value,
  })
);

const resolveDealBoardSortValue = (deal, key) => {
  switch (key) {
    case 'amount':
      return Number(resolveDealAmountMajor(deal) ?? 0);
    case 'createdAt':
      return deal.createdAt ? new Date(deal.createdAt).getTime() : null;
    case 'expectedCloseOn':
      return deal.expectedCloseOn
        ? new Date(deal.expectedCloseOn).getTime()
        : null;
    case 'position':
      return Number(deal.position ?? Number.MAX_SAFE_INTEGER);
    case 'title':
      return normalizeFilterText(deal.title);
    case 'updatedAt':
      return deal.updatedAt ? new Date(deal.updatedAt).getTime() : null;
    default:
      return null;
  }
};

const sortedListDeals = computed(() =>
  sortListRecords(
    filteredListDeals.value,
    listSort.value,
    resolveDealSortValue.value
  )
);

const defaultDealsPreferences = () => ({
  boardSort: {
    key: MANUAL_BOARD_SORT_KEY,
  },
  boardSortDirections: {},
  currentPresentation: 'board',
  filters: {
    aiOnly: false,
    archived: false,
    companyId: '',
    contactId: '',
    ownerId: '',
    pipelineId: '',
    stageId: '',
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

const sanitizeDealsPreferences = preferences => {
  const defaults = defaultDealsPreferences();
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

  if (!['board', 'list'].includes(next.currentPresentation)) {
    next.currentPresentation = defaults.currentPresentation;
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

const restoreDealsPreferences = () => {
  const stored =
    persistedPreferencesByAccount.value?.[accountPreferenceKey.value] || {};
  const preferences = sanitizeDealsPreferences(stored);

  currentPresentation.value = preferences.currentPresentation;
  listSort.value = { ...preferences.listSort };
  boardSort.key = preferences.boardSort.key;
  Object.keys(boardSortDirections).forEach(key => {
    delete boardSortDirections[key];
  });
  Object.assign(boardSortDirections, preferences.boardSortDirections);
  Object.assign(filters, preferences.filters);
  listQuickFilters.q = preferences.listQuickFilters.q;
};

const persistDealsPreferences = () => {
  if (!hasRestoredPreferences.value) return;

  persistedPreferencesByAccount.value = {
    ...(persistedPreferencesByAccount.value || {}),
    [accountPreferenceKey.value]: sanitizeDealsPreferences({
      boardSort: { ...boardSort },
      boardSortDirections: { ...boardSortDirections },
      currentPresentation: currentPresentation.value,
      filters: { ...filters },
      listQuickFilters: { ...listQuickFilters },
      listSort: { ...listSort.value },
    }),
  };
};

const paginatedListDeals = computed(() => {
  const startIndex = (listCurrentPage.value - 1) * LIST_PAGE_SIZE;
  return sortedListDeals.value.slice(startIndex, startIndex + LIST_PAGE_SIZE);
});

const stripedDealRowIds = computed(
  () =>
    new Set(
      paginatedListDeals.value
        .filter((_, index) => index % 2 === 1)
        .map(deal => Number(deal.id))
    )
);

const shouldShowListPagination = computed(
  () => sortedListDeals.value.length > LIST_PAGE_SIZE
);

const dealListRowClass = row => [
  row.archivedAt ? 'opacity-75' : '',
  stripedDealRowIds.value.has(Number(row.id)) ? 'bg-n-surface-1/70' : '',
];

const handleListSortChange = sortState => {
  listCurrentPage.value = 1;
  listSort.value = sortState;
};

const currentUserId = computed(() => {
  const userId = Number(currentUser.value?.id);
  return Number.isFinite(userId) && userId > 0 ? userId : '';
});

const defaultDealCurrency = 'KZT';
const dealCurrencyOptions = ['KZT', 'USD', 'EUR', 'RUB'];

const contactHref = contactId => {
  if (!contactId || !accountId.value) return '';

  return router.resolve({
    name: 'contacts_edit',
    params: {
      accountId: accountId.value,
      contactId,
    },
  }).href;
};

const contactAvatarSrc = contact =>
  contact.thumbnail?.src ||
  (typeof contact.thumbnail === 'string' ? contact.thumbnail : '') ||
  contact.avatarUrl ||
  contact.avatar_url ||
  contact.avatar ||
  contact.imageUrl ||
  contact.image_url ||
  '';

const buildContactOption = contact => {
  const primaryLabel =
    contact.name ||
    contact.phoneNumber ||
    contact.email ||
    contact.identifier ||
    t('CRM.GENERAL.EMPTY_VALUE');
  const secondaryLabel = contact.name
    ? contact.phoneNumber || contact.email || contact.identifier
    : '';

  return {
    href: contactHref(contact.id),
    label: [primaryLabel, secondaryLabel].filter(Boolean).join(' · '),
    thumbnail: {
      name: primaryLabel,
      src: contactAvatarSrc(contact),
    },
    value: contact.id,
  };
};

const buildCompanyOption = company => ({
  label: company.name,
  value: company.id,
});

const dedupeOptions = options => {
  const optionMap = new Map();

  options.forEach(option => {
    const key = Number.isFinite(Number(option.value))
      ? Number(option.value)
      : option.value;
    optionMap.set(key, option);
  });

  return Array.from(optionMap.values());
};

const selectedContactOptionIds = computed(() => {
  return [
    ...form.contactIds.map(Number),
    filterDraft.contactId ? Number(filterDraft.contactId) : null,
    form.primaryContactId ? Number(form.primaryContactId) : null,
  ].filter(Boolean);
});

const selectedCompanyOptionIds = computed(() =>
  [form.companyId, filterDraft.companyId].map(Number).filter(Boolean)
);

const mergeContactOptions = options => {
  const selectedOptions = contactOptions.value.filter(option =>
    selectedContactOptionIds.value.includes(Number(option.value))
  );

  return dedupeOptions([...selectedOptions, ...options]);
};

const mergeCompanyOptions = options => {
  const selectedOptions = companyOptions.value.filter(option =>
    selectedCompanyOptionIds.value.includes(Number(option.value))
  );

  return dedupeOptions([...selectedOptions, ...options]);
};

const upsertContactOption = contact => {
  const option = buildContactOption(contact);
  contactOptions.value = dedupeOptions([option, ...contactOptions.value]);
  return option;
};

const upsertCompanyOption = company => {
  const option = buildCompanyOption(company);
  companyOptions.value = dedupeOptions([option, ...companyOptions.value]);
  return option;
};

const defaultStageForPipeline = pipeline =>
  (pipeline?.stages || []).find(stage => stage.default && stage.active) ||
  (pipeline?.stages || []).find(
    stage => stage.active && stage.outcome === 'open'
  ) ||
  (pipeline?.stages || []).find(stage => stage.active) ||
  pipeline?.stages?.[0];

const resetForm = () => {
  const defaultPipelineId = resolvePipelineFilterId(filters.pipelineId);
  const resolvedDefaultPipeline =
    referencesStore.pipelines.find(
      pipeline => Number(pipeline.id) === Number(defaultPipelineId)
    ) ||
    referencesStore.pipelines.find(pipeline => pipeline.default) ||
    referencesStore.pipelines[0];
  const defaultStage = defaultStageForPipeline(resolvedDefaultPipeline);

  Object.assign(form, {
    amount: 0,
    companyId: '',
    contactIds: [],
    closingReasons: [],
    currency: defaultDealCurrency,
    customAttributes: buildDefaultCustomAttributes(dealFieldDefinitions.value),
    description: '',
    expectedCloseOn: '',
    externalRef: '',
    originatingCommunicationThreadDisplayId: '',
    originatingCommunicationThreadId: '',
    originatingConversationDisplayId: '',
    originatingConversationId: '',
    ownerId: currentUserId.value,
    pipelineId: resolvedDefaultPipeline?.id || '',
    primaryContactId: '',
    stageId: defaultStage?.id || '',
    teamId: '',
    title: '',
    winProbability: '',
  });
};

const populateFormFromDeal = deal => {
  Object.assign(form, {
    amount: resolveDealAmountMajor(deal) ?? 0,
    companyId: deal.companyId ?? '',
    contactIds: (deal.dealContacts || []).map(contact => contact.contactId),
    closingReasons: normalizedTextValues(deal.closingReasons),
    currency: deal.currency || defaultDealCurrency,
    customAttributes: { ...(deal.customAttributes || {}) },
    description: deal.description || '',
    expectedCloseOn: deal.expectedCloseOn
      ? deal.expectedCloseOn.slice(0, 10)
      : '',
    externalRef: deal.externalRef || '',
    originatingCommunicationThreadDisplayId: formatConversationDisplayLabel(
      deal.originatingCommunicationThreadDisplayId ??
        deal.originatingCommunicationThreadId
    ),
    originatingCommunicationThreadId:
      deal.originatingCommunicationThreadDisplayId ??
      deal.originatingCommunicationThreadId ??
      '',
    originatingConversationDisplayId: formatConversationDisplayLabel(
      deal.originatingConversationDisplayId ?? deal.originatingConversationId
    ),
    originatingConversationId: deal.originatingConversationId ?? '',
    ownerId: deal.ownerId ?? '',
    pipelineId: deal.pipelineId,
    primaryContactId: deal.primaryContactId ?? '',
    stageId: deal.stageId,
    teamId: deal.teamId ?? '',
    title: deal.title,
    winProbability: deal.winProbability ?? '',
  });
};

const normalizeSnapshotValue = value => {
  if (Array.isArray(value)) {
    return value.map(normalizeSnapshotValue);
  }

  if (value && typeof value === 'object') {
    return Object.keys(value)
      .sort()
      .reduce((result, key) => {
        result[key] = normalizeSnapshotValue(value[key]);
        return result;
      }, {});
  }

  return value ?? '';
};

const formSnapshotPayload = () =>
  normalizeSnapshotValue({
    amount: form.amount,
    companyId: form.companyId,
    contactIds: form.contactIds,
    closingReasons: form.closingReasons,
    currency: form.currency,
    customAttributes: form.customAttributes,
    description: form.description,
    expectedCloseOn: form.expectedCloseOn,
    externalRef: form.externalRef,
    originatingCommunicationThreadId: form.originatingCommunicationThreadId,
    originatingConversationId: form.originatingConversationId,
    ownerId: form.ownerId,
    pipelineId: form.pipelineId,
    primaryContactId: form.primaryContactId,
    stageId: form.stageId,
    teamId: form.teamId,
    title: form.title.trim(),
    winProbability: form.winProbability,
  });

const captureFormBaseline = () => {
  formBaselineSnapshot.value = JSON.stringify(formSnapshotPayload());
};

const isDealFormDirty = computed(
  () => JSON.stringify(formSnapshotPayload()) !== formBaselineSnapshot.value
);

const shouldShowDealSaveAction = computed(
  () => !selectedDeal.value || isDealFormDirty.value
);

const disableDealSave = computed(
  () => ui.isSaving || !form.title.trim() || !form.pipelineId || !form.stageId
);

const primaryContactOptions = computed(() =>
  contactOptions.value.filter(option =>
    form.contactIds.map(Number).includes(Number(option.value))
  )
);

const shouldShowPrimaryContactSelect = computed(
  () => form.contactIds.length > 1
);

const formatErrorMessage = error => formatCrmErrorMessage(error, t);

const formatDealAmountLabel = deal =>
  formatDealAmount({
    amount: resolveDealAmountMajor(deal),
    currency: deal.currency,
    emptyValue: t('CRM.GENERAL.EMPTY_VALUE'),
    locale: localeCode.value,
  });

const formatDate = value => {
  if (!value) return t('CRM.GENERAL.EMPTY_VALUE');
  return format(new Date(value), 'MMM d, yyyy');
};

const crmPrefillKeys = [
  'action',
  'amount',
  'companyId',
  'companyName',
  'contactId',
  'contactName',
  'communicationThreadDisplayId',
  'conversationDisplayId',
  'currency',
  'dealId',
  'description',
  'expectedCloseOn',
  'originatingCommunicationThreadId',
  'originatingConversationId',
  'ownerId',
  'pipelineId',
  'source',
  'stageId',
  'teamId',
  'title',
  'winProbability',
];

const queryValue = key => {
  const value = route.query[key];
  return Array.isArray(value) ? value[0] : value;
};

const numericQueryValue = key => {
  const value = Number(queryValue(key));
  return Number.isFinite(value) && value > 0 ? value : '';
};

const decimalQueryValue = key => {
  const value = Number(queryValue(key));
  return Number.isFinite(value) && value >= 0 ? value : '';
};

const buildPrefillDealTitle = () => {
  const contactName = queryValue('contactName');
  const companyName = queryValue('companyName');
  const communicationThreadDisplayId = queryValue(
    'communicationThreadDisplayId'
  );
  const conversationDisplayId = queryValue('conversationDisplayId');

  if (contactName) {
    return t('CRM.DEALS.PREFILL.CONVERSATION_WITH_CONTACT', {
      contactName,
    });
  }

  if (companyName) {
    return t('CRM.DEALS.PREFILL.COMPANY', {
      companyName,
    });
  }

  if (communicationThreadDisplayId) {
    return t('CRM.DEALS.PREFILL.COMMUNICATION_THREAD_GENERIC', {
      threadId: communicationThreadDisplayId,
    });
  }

  if (conversationDisplayId) {
    return t('CRM.DEALS.PREFILL.CONVERSATION_GENERIC', {
      conversationId: conversationDisplayId,
    });
  }

  return '';
};

const upsertDeal = deal => {
  const existingIndex = deals.value.findIndex(item => item.id === deal.id);

  if (existingIndex === -1) {
    deals.value = [deal, ...deals.value];
    return;
  }

  const nextDeals = [...deals.value];
  nextDeals.splice(existingIndex, 1, deal);
  deals.value = nextDeals;
};

const removeDeal = dealId => {
  deals.value = deals.value.filter(item => Number(item.id) !== Number(dealId));
};

const hasCustomFieldFilters = () =>
  Object.keys(customFieldFilters.value || {}).length > 0;

const dealMatchesCurrentFilters = deal => {
  if (hasCustomFieldFilters()) return null;

  const archived = Boolean(deal.archivedAt);
  if (archived !== Boolean(filters.archived)) return false;
  if (filters.aiOnly && deal.dialogStatus !== 'pending') return false;
  if (
    filters.companyId &&
    Number(deal.companyId) !== Number(filters.companyId)
  ) {
    return false;
  }
  if (filters.ownerId && Number(deal.ownerId) !== Number(filters.ownerId)) {
    return false;
  }
  if (
    filters.pipelineId &&
    Number(deal.pipelineId) !== Number(filters.pipelineId)
  ) {
    return false;
  }
  if (filters.stageId && Number(deal.stageId) !== Number(filters.stageId)) {
    return false;
  }
  if (filters.teamId && Number(deal.teamId) !== Number(filters.teamId)) {
    return false;
  }
  if (filters.contactId) {
    return (deal.dealContacts || []).some(
      contact => Number(contact.contactId) === Number(filters.contactId)
    );
  }

  return true;
};

const loadContacts = async query => {
  const response = query
    ? await ContactAPI.search(query, 1)
    : await ContactAPI.get(1);
  contactOptions.value = mergeContactOptions(
    normalizePayload(response.data).map(buildContactOption)
  );
};

const loadCompanies = async query => {
  if (!companiesEnabled.value) {
    companyOptions.value = [];
    return;
  }

  const response = query
    ? await CompanyAPI.search(query, 1)
    : await CompanyAPI.get();
  companyOptions.value = mergeCompanyOptions(
    normalizePayload(response.data).map(buildCompanyOption)
  );
};

const ensureSelectedLookups = async deal => {
  const contactIds = (deal.dealContacts || []).map(
    contact => contact.contactId
  );
  const missingContactIds = contactIds.filter(
    contactId =>
      !contactOptions.value.some(
        option => Number(option.value) === Number(contactId)
      )
  );
  const missingCompanyId =
    deal.companyId &&
    !companyOptions.value.some(
      option => Number(option.value) === Number(deal.companyId)
    );

  if (missingContactIds.length) {
    const responses = await Promise.all(
      missingContactIds.map(contactId => ContactAPI.show(contactId))
    );
    const resolvedContacts = responses.map(response =>
      normalizePayload(response.data)
    );
    contactOptions.value = dedupeOptions([
      ...contactOptions.value,
      ...resolvedContacts.map(buildContactOption),
    ]);
  }

  if (missingCompanyId && companiesEnabled.value) {
    const response = await CompanyAPI.show(deal.companyId);
    const company = normalizePayload(response.data);
    upsertCompanyOption(company);
  }
};

const resolveStageFilterId = (stageId, pipelineId) => {
  if (!stageId) return '';

  const resolvedPipelineId = resolvePipelineFilterId(pipelineId);
  const pipeline = referencesStore.pipelines.find(
    item => Number(item.id) === Number(resolvedPipelineId)
  );
  const belongsToPipeline = (pipeline?.stages || []).some(
    stage => Number(stage.id) === Number(stageId)
  );

  return belongsToPipeline ? stageId : '';
};

const hasDealListFilterQuery = () => {
  return (
    !queryValue('action') &&
    !numericQueryValue('dealId') &&
    (numericQueryValue('pipelineId') || numericQueryValue('stageId'))
  );
};

const applyDealListFilterQuery = () => {
  if (!hasDealListFilterQuery()) return false;

  const nextPipelineId = resolvePipelineFilterId(
    numericQueryValue('pipelineId') || filters.pipelineId
  );
  const nextStageId = resolveStageFilterId(
    numericQueryValue('stageId'),
    nextPipelineId
  );
  const filtersChanged =
    String(filters.pipelineId || '') !== String(nextPipelineId || '') ||
    String(filters.stageId || '') !== String(nextStageId || '');

  listCurrentPage.value = 1;
  filters.pipelineId = nextPipelineId;
  filters.stageId = nextStageId;
  filterDraft.pipelineId = nextPipelineId;
  filterDraft.stageId = nextStageId;

  return filtersChanged;
};

const ensureSelectedFilterLookups = async () => {
  if (
    filterDraft.contactId &&
    !contactOptions.value.some(
      option => Number(option.value) === Number(filterDraft.contactId)
    )
  ) {
    const response = await ContactAPI.show(filterDraft.contactId);
    upsertContactOption(normalizePayload(response.data));
  }

  if (
    filterDraft.companyId &&
    companiesEnabled.value &&
    !companyOptions.value.some(
      option => Number(option.value) === Number(filterDraft.companyId)
    )
  ) {
    const response = await CompanyAPI.show(filterDraft.companyId);
    upsertCompanyOption(normalizePayload(response.data));
  }
};

const loadTimeline = async dealId => {
  ui.isTimelineLoading = true;

  try {
    const { data } = await CrmDealsAPI.timeline(dealId, { limit: 50 });
    timelineItems.value = normalizePayload(data);
  } finally {
    ui.isTimelineLoading = false;
  }
};

const openCreateDrawer = async prefill => {
  closeDealTitleEditor();
  selectedDeal.value = null;
  pendingCreateCustomFieldDefaultsHydration.value = true;
  resetForm();
  drawerOpen.value = true;
  timelineItems.value = [];
  showLinkedConversationPanel.value = false;
  await Promise.all([loadContacts(''), loadCompanies('')]);

  if (prefill) {
    Object.assign(form, prefill);
    showLinkedConversationPanel.value = canOpenLinkedConversation.value;
  }

  captureFormBaseline();
};

const openEditDrawer = async deal => {
  closeDealTitleEditor();
  pendingCreateCustomFieldDefaultsHydration.value = false;
  selectedDeal.value = deal;
  populateFormFromDeal(deal);
  drawerOpen.value = true;
  showLinkedConversationPanel.value = canOpenLinkedConversation.value;
  await Promise.all([loadContacts(''), loadCompanies('')]);
  await ensureSelectedLookups(deal);
  await loadTimeline(deal.id);
  captureFormBaseline();
};

const closeDrawer = () => {
  closeDealTitleEditor();
  pendingCreateCustomFieldDefaultsHydration.value = false;
  drawerOpen.value = false;
  showLinkedConversationPanel.value = false;
  selectedDeal.value = null;
  timelineItems.value = [];
  resetForm();
  captureFormBaseline();
};

const openCreateNewContactDialog = () => {
  createNewContactDialogRef.value?.dialogRef.open();
};

const openCreateCompanyDialog = () => {
  createCompanyDialogRef.value?.dialogRef?.open();
};

const buildCreateTaskTitleForDeal = deal =>
  t('CRM.TASKS.PREFILL.DEAL', {
    dealTitle: deal?.title || `#${deal?.id}`,
  });

const openCreateTaskForDeal = deal => {
  if (!deal?.id || !canManageTasks.value) return;

  router.push({
    name: 'crm_tasks_index',
    params: { accountId: accountId.value },
    query: compactPayload({
      action: 'new',
      assigneeId: deal.ownerId,
      conversationDisplayId:
        deal.originatingConversationDisplayId || deal.originatingConversationId,
      dealId: deal.id,
      originatingConversationId: deal.originatingConversationId,
      source: 'deal',
      teamId: deal.teamId,
      title: buildCreateTaskTitleForDeal(deal),
    }),
  });
};

const createContact = async contact => {
  try {
    const createdContact = await store.dispatch('contacts/create', contact);
    createNewContactDialogRef.value?.onSuccess();

    const createdOption = upsertContactOption(createdContact);
    form.contactIds = [
      ...new Set([...form.contactIds, createdOption.value].map(Number)),
    ];

    if (!form.primaryContactId) {
      form.primaryContactId = createdOption.value;
    }

    useAlert(
      t('CONTACTS_LAYOUT.HEADER.ACTIONS.CONTACT_CREATION.SUCCESS_MESSAGE')
    );
  } catch (error) {
    if (error instanceof DuplicateContactException) {
      if (error.data.includes('email')) {
        useAlert(
          t(
            'CONTACTS_LAYOUT.HEADER.ACTIONS.CONTACT_CREATION.EMAIL_ADDRESS_DUPLICATE'
          )
        );
      } else if (error.data.includes('phone_number')) {
        useAlert(
          t(
            'CONTACTS_LAYOUT.HEADER.ACTIONS.CONTACT_CREATION.PHONE_NUMBER_DUPLICATE'
          )
        );
      }
    } else if (error instanceof ExceptionWithMessage) {
      useAlert(error.data);
    } else {
      useAlert(
        t('CONTACTS_LAYOUT.HEADER.ACTIONS.CONTACT_CREATION.ERROR_MESSAGE')
      );
    }
  }
};

const createCompany = async company => {
  try {
    const response = await CompanyAPI.create(company);
    const createdCompany = normalizePayload(response.data);
    createCompanyDialogRef.value?.onSuccess?.();

    const createdOption = upsertCompanyOption(createdCompany);
    form.companyId = createdOption.value;

    useAlert(t('COMPANIES.FORM.SUCCESS.CREATE'));
  } catch {
    useAlert(t('COMPANIES.FORM.ERROR.CREATE'));
  }
};

const syncSelectedDeal = records => {
  if (!selectedDeal.value) return;

  const nextSelectedDeal = records.find(
    deal => Number(deal.id) === Number(selectedDeal.value.id)
  );

  if (nextSelectedDeal) {
    selectedDeal.value = nextSelectedDeal;
  }
};

const buildPayload = () => {
  return compactPayload({
    amount_minor: majorAmountToMinor(form.amount),
    company_id: form.companyId ? Number(form.companyId) : undefined,
    contact_ids: form.contactIds.map(Number),
    closing_reasons: normalizedTextValues(form.closingReasons),
    currency: form.currency || undefined,
    custom_attributes: form.customAttributes,
    description: form.description || undefined,
    expected_close_on: form.expectedCloseOn || undefined,
    external_ref: form.externalRef || undefined,
    lock_version: selectedDeal.value?.lockVersion,
    originating_communication_thread_id: form.originatingCommunicationThreadId
      ? Number(form.originatingCommunicationThreadId)
      : undefined,
    originating_conversation_id: form.originatingConversationId
      ? Number(form.originatingConversationId)
      : undefined,
    owner_id: form.ownerId ? Number(form.ownerId) : undefined,
    pipeline_id: Number(form.pipelineId),
    primary_contact_id: form.primaryContactId
      ? Number(form.primaryContactId)
      : undefined,
    stage_id: form.stageId ? Number(form.stageId) : undefined,
    team_id: form.teamId ? Number(form.teamId) : undefined,
    title: form.title.trim(),
    win_probability:
      form.winProbability === '' || form.winProbability === null
        ? undefined
        : Number(form.winProbability),
  });
};

const saveDeal = async () => {
  if (!canManageDeals.value) return;

  const targetStage = findStageById(form.stageId);
  const stageChanging =
    !selectedDeal.value ||
    Number(form.stageId) !== Number(selectedDeal.value.stageId);

  let transitionReason = '';

  if (stageChanging) {
    const closingReasons = await collectClosingReasonsForStage({
      deal: selectedDeal.value,
      targetStage,
    });

    if (closingReasons === null) return;

    transitionReason = selectedDeal.value
      ? await collectTransitionReasonForStage({ targetStage })
      : '';

    if (transitionReason === null) return;

    form.closingReasons = closingReasons;
  }

  ui.isSaving = true;

  try {
    const wasEditingDeal = !!selectedDeal.value;
    const payload = buildPayload();
    let deal;

    if (selectedDeal.value) {
      const currentStageId = selectedDeal.value.stageId;
      const {
        closing_reasons: _closingReasons,
        stage_id: _stageId,
        ...updatePayload
      } = payload;
      const response = await CrmDealsAPI.update(
        selectedDeal.value.id,
        updatePayload
      );
      deal = normalizePayload(response.data);

      if (Number(form.stageId) !== Number(currentStageId) && form.stageId) {
        const transitionResponse = await CrmDealsAPI.transitionStage(deal.id, {
          closing_reasons: form.closingReasons,
          lock_version: deal.lockVersion,
          stage_id: Number(form.stageId),
          transition_reason: transitionReason || undefined,
        });
        deal = normalizePayload(transitionResponse.data);
      }
    } else {
      const response = await CrmDealsAPI.create(payload);
      deal = normalizePayload(response.data);
    }

    upsertDeal(deal);
    selectedDeal.value = deal;
    pendingCreateCustomFieldDefaultsHydration.value = false;
    populateFormFromDeal(deal);
    captureFormBaseline();
    await Promise.allSettled([
      ensureSelectedLookups(deal),
      loadTimeline(deal.id),
    ]);
    useAlert(
      wasEditingDeal
        ? t('CRM.DEALS.SUCCESS_UPDATED')
        : t('CRM.DEALS.SUCCESS_CREATED')
    );
  } catch (error) {
    useAlert(formatErrorMessage(error));
  } finally {
    ui.isSaving = false;
  }
};

const toggleArchived = async deal => {
  try {
    const response = deal.archivedAt
      ? await CrmDealsAPI.unarchive(deal.id, {
          lock_version: deal.lockVersion,
        })
      : await CrmDealsAPI.archive(deal.id, {
          lock_version: deal.lockVersion,
        });
    const updatedDeal = normalizePayload(response.data);
    upsertDeal(updatedDeal);
    if (
      selectedDeal.value &&
      Number(selectedDeal.value.id) === Number(updatedDeal.id)
    ) {
      selectedDeal.value = updatedDeal;
    }
    useAlert(
      deal.archivedAt
        ? t('CRM.DEALS.SUCCESS_UNARCHIVED')
        : t('CRM.DEALS.SUCCESS_ARCHIVED')
    );
  } catch (error) {
    useAlert(formatErrorMessage(error));
  }
};

async function loadDeals() {
  ui.isLoading = true;
  ui.error = null;

  try {
    const { data } = await CrmDealsAPI.get(
      compactPayload({
        ai_only: filters.aiOnly || undefined,
        archived: filters.archived,
        company_id: filters.companyId || undefined,
        contact_id: filters.contactId || undefined,
        owner_id: filters.ownerId || undefined,
        pipeline_id: filters.pipelineId || undefined,
        stage_id: filters.stageId || undefined,
        team_id: filters.teamId || undefined,
        custom_attribute_filters: customFieldFilters.value,
      })
    );
    deals.value = normalizePayload(data);
    syncSelectedDeal(deals.value);
  } catch (error) {
    ui.error = error;
  } finally {
    ui.isLoading = false;
  }
}

const scheduleDealsReload = useDebounceFn(() => {
  loadDeals();
}, 300);

const handleCrmDealRealtimeEvent = payload => {
  const realtimeDeal = normalizePayload({ payload: payload?.deal });
  if (!realtimeDeal?.id) return;

  const isSelectedDeal =
    selectedDeal.value &&
    Number(selectedDeal.value.id) === Number(realtimeDeal.id);
  if (isSelectedDeal) {
    selectedDeal.value = realtimeDeal;
  }

  const filterMatch = dealMatchesCurrentFilters(realtimeDeal);
  if (filterMatch === null) {
    scheduleDealsReload();
    return;
  }

  if (filterMatch) {
    upsertDeal(realtimeDeal);
  } else {
    removeDeal(realtimeDeal.id);
  }

  if (CRM_DEAL_ARCHIVE_EVENTS.has(payload?.event)) {
    syncSelectedDeal(deals.value);
  }
};

const startEditingDealTitle = deal => {
  if (!canManageDeals.value) {
    openEditDrawer(deal);
    return;
  }

  editingDealTitleId.value = deal.id;
  dealTitleDraft.value = deal.title || '';
};

const saveDealTitle = async deal => {
  const currentDeal =
    deals.value.find(item => Number(item.id) === Number(deal.id)) || deal;
  const nextTitle = String(dealTitleDraft.value || '').trim();
  const currentTitle = String(currentDeal.title || '').trim();

  if (!nextTitle || nextTitle === currentTitle) {
    closeDealTitleEditor();
    return;
  }

  if (savingDealTitleId.value === currentDeal.id) {
    return;
  }

  savingDealTitleId.value = currentDeal.id;
  const optimisticDeal = { ...currentDeal, title: nextTitle };
  upsertDeal(optimisticDeal);

  if (
    selectedDeal.value &&
    Number(selectedDeal.value.id) === optimisticDeal.id
  ) {
    selectedDeal.value = optimisticDeal;
    form.title = nextTitle;
  }

  try {
    const response = await CrmDealsAPI.update(currentDeal.id, {
      lock_version: currentDeal.lockVersion,
      title: nextTitle,
    });
    const updatedDeal = normalizePayload(response.data);
    upsertDeal(updatedDeal);

    if (
      selectedDeal.value &&
      Number(selectedDeal.value.id) === updatedDeal.id
    ) {
      selectedDeal.value = updatedDeal;
      form.title = updatedDeal.title;
    }
  } catch (error) {
    try {
      await loadDeals();
    } catch {
      // Keep the original API error as the surfaced failure.
    }

    useAlert(formatErrorMessage(error));
  } finally {
    savingDealTitleId.value = null;
    closeDealTitleEditor();
  }
};

const ensurePipelineFilterSelection = () => {
  const nextPipelineId = resolvePipelineFilterId(filters.pipelineId);
  if (!nextPipelineId) return;

  filters.pipelineId = nextPipelineId;
  filterDraft.pipelineId = nextPipelineId;
};

const selectPipelineFilter = async pipelineId => {
  const nextPipelineId = resolvePipelineFilterId(pipelineId);
  if (!nextPipelineId || isActivePipeline(nextPipelineId)) return;

  listCurrentPage.value = 1;
  filters.pipelineId = nextPipelineId;
  filters.stageId = resolveStageFilterId(filters.stageId, nextPipelineId);
  filterDraft.pipelineId = nextPipelineId;
  filterDraft.stageId = resolveStageFilterId(
    filterDraft.stageId,
    nextPipelineId
  );
  await loadDeals();
};

const openCreateStageSetup = () => {
  if (!canManageDeals.value || !selectedPipeline.value) return;

  router.push({
    name: 'crm_settings_index',
    params: { accountId: accountId.value },
    query: {
      action: 'create-stage',
      pipelineId: selectedPipeline.value.id,
    },
  });
};

const openDealSettings = () => {
  if (!canAccessDealSettings.value) return;

  router.push({
    name: 'crm_settings_index',
    params: { accountId: accountId.value },
  });
};

const handleAiOnlyFilterChange = async value => {
  filters.aiOnly = Boolean(value);
  listCurrentPage.value = 1;
  await loadDeals();
};

const handleBoardCreateDeal = async ({ pipelineId, stageId }) => {
  await openCreateDrawer({
    pipelineId,
    stageId,
  });
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

const updateDealCustomFieldFilterDraft = (key, value) => {
  customFieldFilterDraft.value = {
    ...customFieldFilterDraft.value,
    [key]: value,
  };
};

const syncFilterDraft = () => {
  Object.assign(filterDraft, {
    archived: filters.archived,
    companyId: filters.companyId,
    contactId: filters.contactId,
    ownerId: filters.ownerId,
    pipelineId: filters.pipelineId,
    stageId: resolveStageFilterId(filters.stageId, filters.pipelineId),
    teamId: filters.teamId,
  });
  customFieldFilterDraft.value = { ...customFieldFilters.value };
};

const openFilterDialog = async () => {
  syncFilterDraft();
  await ensureSelectedFilterLookups();
  filterDialogRef.value?.open();
};

const applyFilters = async () => {
  listCurrentPage.value = 1;
  Object.assign(filters, {
    archived: filterDraft.archived,
    companyId: filterDraft.companyId,
    contactId: filterDraft.contactId,
    ownerId: filterDraft.ownerId,
    pipelineId: resolvePipelineFilterId(filterDraft.pipelineId),
    stageId: resolveStageFilterId(
      filterDraft.stageId,
      resolvePipelineFilterId(filterDraft.pipelineId)
    ),
    teamId: filterDraft.teamId,
  });
  customFieldFilters.value = normalizeCustomFieldFilters(
    filterableDealFieldDefinitions.value,
    customFieldFilterDraft.value,
    customFieldFilterLabels.value
  );
  filterDialogRef.value?.close();
  await loadDeals();
};

watch(
  filterableDealFieldDefinitions,
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
  () => listQuickFilters.q,
  () => {
    listCurrentPage.value = 1;
  }
);

watch(filteredListDeals, rows => {
  if (!rows.length) {
    listCurrentPage.value = 1;
    return;
  }

  const maxPage = Math.max(1, Math.ceil(rows.length / LIST_PAGE_SIZE));

  if (listCurrentPage.value > maxPage) {
    listCurrentPage.value = maxPage;
  }
});

const handleDealStageChange = async ({ deal, stageId, position }) => {
  const currentDeal =
    deals.value.find(item => Number(item.id) === Number(deal.id)) || deal;
  const nextStageId = Number(stageId);
  const nextPosition = Number(position);

  if (
    !nextStageId ||
    (Number(currentDeal.stageId) === nextStageId &&
      (!nextPosition || Number(currentDeal.position) === nextPosition))
  ) {
    return;
  }

  const stageChanging = Number(currentDeal.stageId) !== nextStageId;
  const targetStage = findStageById(nextStageId);
  const closingReasons = stageChanging
    ? await collectClosingReasonsForStage({ deal: currentDeal, targetStage })
    : [];

  if (closingReasons === null) {
    await loadDeals();
    return;
  }

  const transitionReason = stageChanging
    ? await collectTransitionReasonForStage({ targetStage })
    : '';

  if (transitionReason === null) {
    await loadDeals();
    return;
  }

  if (
    selectedDeal.value &&
    Number(selectedDeal.value.id) === Number(currentDeal.id)
  ) {
    selectedDeal.value = {
      ...selectedDeal.value,
      closingReasons: stageChanging
        ? closingReasons
        : selectedDeal.value.closingReasons,
      position: nextPosition || selectedDeal.value.position,
      stageId: nextStageId,
    };
    form.stageId = nextStageId;
  }

  try {
    const response =
      Number(currentDeal.stageId) === nextStageId
        ? await CrmDealsAPI.update(currentDeal.id, {
            lock_version: currentDeal.lockVersion,
            position: nextPosition || currentDeal.position,
          })
        : await CrmDealsAPI.transitionStage(currentDeal.id, {
            closing_reasons: closingReasons,
            lock_version: currentDeal.lockVersion,
            position: nextPosition || undefined,
            stage_id: nextStageId,
            transition_reason: transitionReason || undefined,
          });
    const updatedDeal = normalizePayload(response.data);
    upsertDeal(updatedDeal);

    if (
      selectedDeal.value &&
      Number(selectedDeal.value.id) === updatedDeal.id
    ) {
      selectedDeal.value = updatedDeal;
      form.stageId = updatedDeal.stageId;
    }
  } catch (error) {
    try {
      await loadDeals();

      if (selectedDeal.value) {
        selectedDeal.value =
          deals.value.find(
            item => Number(item.id) === Number(currentDeal.id)
          ) || selectedDeal.value;
      }
    } catch {
      // Keep the original API error as the surfaced failure.
    }

    useAlert(formatErrorMessage(error));
  }
};

const handleDealOwnerChange = async ({ deal, ownerId }) => {
  const currentDeal =
    deals.value.find(item => Number(item.id) === Number(deal.id)) || deal;
  const nextOwnerId = Number(ownerId);

  if (!nextOwnerId || Number(currentDeal.ownerId) === nextOwnerId) {
    return;
  }

  const optimisticDeal = { ...currentDeal, ownerId: nextOwnerId };
  upsertDeal(optimisticDeal);

  if (
    selectedDeal.value &&
    Number(selectedDeal.value.id) === optimisticDeal.id
  ) {
    selectedDeal.value = optimisticDeal;
    form.ownerId = nextOwnerId;
  }

  try {
    const response = await CrmDealsAPI.update(currentDeal.id, {
      lock_version: currentDeal.lockVersion,
      owner_id: nextOwnerId,
    });
    const updatedDeal = normalizePayload(response.data);
    upsertDeal(updatedDeal);

    if (
      selectedDeal.value &&
      Number(selectedDeal.value.id) === updatedDeal.id
    ) {
      selectedDeal.value = updatedDeal;
      form.ownerId = updatedDeal.ownerId;
    }
  } catch (error) {
    try {
      await loadDeals();
    } catch {
      // Keep the original API error as the surfaced failure.
    }

    useAlert(formatErrorMessage(error));
  }
};

const saveComment = async body => {
  if (!selectedDeal.value) return;

  ui.isSavingComment = true;
  try {
    await CrmDealsAPI.createComment(selectedDeal.value.id, { body });
    await loadTimeline(selectedDeal.value.id);
  } catch (error) {
    useAlert(formatErrorMessage(error));
  } finally {
    ui.isSavingComment = false;
  }
};

const deleteComment = async comment => {
  if (!selectedDeal.value) return;

  ui.isSavingComment = true;
  try {
    await CrmDealsAPI.deleteComment(selectedDeal.value.id, comment.id);
    await loadTimeline(selectedDeal.value.id);
  } catch (error) {
    useAlert(formatErrorMessage(error));
  } finally {
    ui.isSavingComment = false;
  }
};

const clearDealPrefillQuery = async () => {
  const nextQuery = { ...route.query };
  crmPrefillKeys.forEach(key => {
    delete nextQuery[key];
  });

  await router.replace({ query: nextQuery });
};

const consumeDealPrefillQuery = async () => {
  if (queryValue('action') !== 'new') return;

  if (!canManageDeals.value) {
    await clearDealPrefillQuery();
    return;
  }

  const contactId = numericQueryValue('contactId');
  const companyId = numericQueryValue('companyId');

  await openCreateDrawer({
    amount: decimalQueryValue('amount') || 0,
    companyId,
    contactIds: contactId ? [contactId] : [],
    currency: queryValue('currency') || defaultDealCurrency,
    description: queryValue('description') || '',
    expectedCloseOn: queryValue('expectedCloseOn') || '',
    originatingCommunicationThreadDisplayId: queryValue(
      'communicationThreadDisplayId'
    )
      ? `#${queryValue('communicationThreadDisplayId')}`
      : '',
    originatingCommunicationThreadId:
      numericQueryValue('originatingCommunicationThreadId') ||
      numericQueryValue('communicationThreadDisplayId'),
    originatingConversationDisplayId: queryValue('conversationDisplayId')
      ? `#${queryValue('conversationDisplayId')}`
      : '',
    originatingConversationId:
      numericQueryValue('originatingConversationId') ||
      numericQueryValue('conversationDisplayId'),
    ownerId: numericQueryValue('ownerId'),
    pipelineId: numericQueryValue('pipelineId') || form.pipelineId,
    primaryContactId: contactId,
    stageId: numericQueryValue('stageId') || form.stageId,
    teamId: numericQueryValue('teamId'),
    title: queryValue('title') || buildPrefillDealTitle(),
    winProbability: decimalQueryValue('winProbability'),
  });

  if (
    contactId &&
    !contactOptions.value.some(
      option => Number(option.value) === Number(contactId)
    )
  ) {
    const response = await ContactAPI.show(contactId);
    const contact = normalizePayload(response.data);
    contactOptions.value = [
      ...contactOptions.value,
      {
        label: [contact.name, contact.phoneNumber].filter(Boolean).join(' · '),
        value: contact.id,
      },
    ];
  }

  if (
    companyId &&
    companiesEnabled.value &&
    !companyOptions.value.some(
      option => Number(option.value) === Number(companyId)
    )
  ) {
    const response = await CompanyAPI.show(companyId);
    upsertCompanyOption(normalizePayload(response.data));
  }

  await clearDealPrefillQuery();
};

const consumeDealOpenQuery = async () => {
  const dealId = numericQueryValue('dealId');
  if (!dealId) return false;

  try {
    let deal = deals.value.find(record => Number(record.id) === Number(dealId));
    if (!deal) {
      const { data } = await CrmDealsAPI.show(dealId);
      deal = normalizePayload(data);
      upsertDeal(deal);
    }

    await openEditDrawer(deal);
  } catch (error) {
    useAlert(formatErrorMessage(error));
  } finally {
    await clearDealPrefillQuery();
  }

  return true;
};

watch(
  dealFieldDefinitions,
  definitions => {
    if (
      !drawerOpen.value ||
      selectedDeal.value ||
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
  () => form.pipelineId,
  pipelineId => {
    const pipeline = referencesStore.pipelines.find(
      item => Number(item.id) === Number(pipelineId)
    );
    const defaultStage = defaultStageForPipeline(pipeline);

    if (
      !pipeline?.stages?.some(
        stage => Number(stage.id) === Number(form.stageId)
      )
    ) {
      form.stageId = defaultStage?.id || '';
    }
  }
);

watch(
  () => [...form.contactIds],
  contactIds => {
    const normalizedContactIds = contactIds.map(Number);

    if (!normalizedContactIds.length) {
      form.primaryContactId = '';
      return;
    }

    if (
      !form.primaryContactId ||
      !normalizedContactIds.includes(Number(form.primaryContactId))
    ) {
      form.primaryContactId = normalizedContactIds[0] || '';
    }
  }
);

watch(
  [
    linkedConversationId,
    linkedCommunicationThreadId,
    linkedConversationDisplayId,
    linkedCommunicationThreadDisplayId,
  ],
  ([
    conversationId,
    communicationThreadId,
    conversationDisplayId,
    communicationThreadDisplayId,
  ]) => {
    if (
      !conversationId &&
      !communicationThreadId &&
      !conversationDisplayId &&
      !communicationThreadDisplayId
    ) {
      showLinkedConversationPanel.value = false;
    }
  }
);

watch(
  [
    currentPresentation,
    listSort,
    () => ({ ...boardSort }),
    () => ({ ...boardSortDirections }),
    () => ({ ...filters }),
    () => listQuickFilters.q,
  ],
  () => {
    persistDealsPreferences();
  },
  { deep: true }
);

const toggleBoardSortDirection = stageId => {
  const key = String(stageId);
  boardSortDirections[key] =
    boardSortDirections[key] === 'desc' ? 'asc' : 'desc';
};

onBeforeRouteLeave(() => {
  showLinkedConversationPanel.value = false;
  filterDialogRef.value?.close?.();

  if (drawerOpen.value) {
    closeDrawer();
  }
});

onBeforeUnmount(() => {
  emitter.off(BUS_EVENTS.CRM_DEAL_REALTIME_EVENT, handleCrmDealRealtimeEvent);
  scheduleDealsReload.cancel?.();
});

const handleDealUiActionQuery = async () => {
  if (!hasRestoredPreferences.value || !canViewDeals.value) return;
  if (dealUiActionQueryInFlight.value) return;

  dealUiActionQueryInFlight.value = true;
  try {
    if (await consumeDealOpenQuery()) return;
    await consumeDealPrefillQuery();
  } finally {
    dealUiActionQueryInFlight.value = false;
  }
};

onMounted(async () => {
  if (!canViewDeals.value) return;

  try {
    emitter.on(BUS_EVENTS.CRM_DEAL_REALTIME_EVENT, handleCrmDealRealtimeEvent);
    restoreDealsPreferences();

    if (!agents.value.length) {
      await store.dispatch('agents/get');
    }

    if (!teams.value.length) {
      await store.dispatch('teams/get');
    }

    await Promise.all([
      referencesStore.loadPipelines(),
      referencesStore.loadFieldDefinitions('deal'),
    ]);
    ensurePipelineFilterSelection();
    applyDealListFilterQuery();
    resetForm();
    hasRestoredPreferences.value = true;
    persistDealsPreferences();
    await loadDeals();
    await handleDealUiActionQuery();
  } catch (error) {
    ui.error = error;
    useAlert(formatErrorMessage(error));
  }
});

watch(
  () => [route.query?.pipelineId, route.query?.stageId],
  async () => {
    if (!hasRestoredPreferences.value || !canViewDeals.value) return;
    if (!applyDealListFilterQuery()) return;

    await loadDeals();
  }
);

watch(
  () => [
    route.query?.dealId,
    route.query?.action,
    route.query?.source,
    route.query?.title,
    route.query?.description,
    route.query?.amount,
    route.query?.currency,
    route.query?.expectedCloseOn,
    route.query?.contactId,
    route.query?.companyId,
    route.query?.ownerId,
    route.query?.teamId,
    route.query?.pipelineId,
    route.query?.stageId,
    route.query?.winProbability,
    route.query?.communicationThreadDisplayId,
    route.query?.conversationDisplayId,
    route.query?.originatingCommunicationThreadId,
    route.query?.originatingConversationId,
  ],
  handleDealUiActionQuery
);
</script>

<template>
  <section class="relative flex flex-1 min-h-0 overflow-hidden bg-n-slate-2">
    <div class="flex min-w-0 flex-1 flex-col overflow-hidden md:order-last">
      <SchedulingPageHeader
        class="!bg-n-slate-2"
        :title="$t('CRM.DEALS.TITLE')"
      >
        <template #title-actions>
          <Button
            v-if="canAccessDealSettings"
            size="sm"
            color="slate"
            variant="ghost"
            icon="i-lucide-settings-2"
            class="!size-7 !text-n-slate-11 hover:!text-n-slate-12"
            :aria-label="$t('SIDEBAR.SETTINGS')"
            :title="$t('SIDEBAR.SETTINGS')"
            @click="openDealSettings"
          />
        </template>
        <template #left>
          <label
            v-for="pipeline in pipelineToggleItems"
            :key="pipeline.id"
            class="relative flex cursor-pointer items-center gap-1.5 rounded-full border px-2.5 py-1.5 transition-colors focus-within:outline focus-within:outline-2 focus-within:outline-n-weak focus-within:outline-offset-2"
            :class="
              isActivePipeline(pipeline.value)
                ? 'border-n-weak bg-n-solid-1 text-n-slate-12 shadow-[0_1px_2px_rgba(15,23,42,0.04)]'
                : 'border-transparent bg-transparent text-n-slate-11 hover:bg-n-alpha-black2/60 hover:text-n-slate-12'
            "
          >
            <input
              :id="pipeline.id"
              class="size-3 flex-shrink-0 border-n-slate-6 text-n-slate-12 focus:ring-n-weak focus:ring-offset-0"
              type="radio"
              name="crm-deals-pipeline"
              :value="pipeline.value"
              :checked="isActivePipeline(pipeline.value)"
              @change="selectPipelineFilter(pipeline.value)"
            />
            <span class="text-xs font-medium leading-none">
              {{ pipeline.label }}
            </span>
          </label>
        </template>
        <template #actions>
          <div
            class="flex h-8 items-center gap-2 rounded-lg border border-n-weak px-2.5 text-xs font-medium text-n-slate-11"
          >
            <Switch
              :model-value="filters.aiOnly"
              :aria-label="$t('CRM.DEALS.AI_ONLY')"
              @change="handleAiOnlyFilterChange"
            />
            <span class="whitespace-nowrap text-n-slate-12">
              {{ $t('CRM.DEALS.AI_ONLY') }}
            </span>
          </div>
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
            :placeholder="$t('CRM.DEALS.LIST.SEARCH_PLACEHOLDER')"
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
          <SchedulingViewSwitcher
            v-model="currentPresentation"
            :views="viewOptions"
          />
          <Button
            v-if="canManageDeals"
            size="sm"
            icon="i-lucide-plus"
            :label="$t('CRM.DEALS.NEW_DEAL')"
            @click="openCreateDrawer"
          />
        </template>
      </SchedulingPageHeader>

      <div
        class="flex-1"
        :class="
          shouldRenderBoard && !ui.isLoading && !ui.error
            ? 'min-h-0 overflow-hidden'
            : 'overflow-y-auto'
        "
      >
        <div
          :class="
            shouldRenderBoard && !ui.isLoading && !ui.error
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
            @retry="loadDeals"
          />

          <SchedulingEmptyState
            v-else-if="currentPresentation === 'board' && !hasBoardStages"
            icon="i-lucide-columns-3"
            :title="$t('CRM.DEALS.BOARD.EMPTY_PIPELINE_TITLE')"
            :description="$t('CRM.DEALS.BOARD.EMPTY_PIPELINE_DESCRIPTION')"
            :action-label="
              canManageDeals ? $t('CRM.DEALS.BOARD.CREATE_STAGE') : ''
            "
            @action="openCreateStageSetup"
          />

          <CrmDealBoard
            v-else-if="currentPresentation === 'board'"
            class="min-h-0 flex-1"
            :can-manage="canManageDeals"
            :deals="deals"
            :field-definitions="dealFieldDefinitions"
            :owners="ownerOptions"
            :show-sort-toggle="boardSort.key !== MANUAL_BOARD_SORT_KEY"
            :stages="boardStages"
            :sort-direction-labels="boardSortDirectionLabels"
            :sort-directions="boardSortDirections"
            :sort-key="boardSort.key"
            :sort-value-resolver="resolveDealBoardSortValue"
            @change-owner="handleDealOwnerChange"
            @change-stage="handleDealStageChange"
            @create-deal="handleBoardCreateDeal"
            @select-deal="openEditDrawer"
            @toggle-sort-direction="toggleBoardSortDirection"
          />

          <SchedulingEmptyState
            v-else-if="deals.length === 0"
            icon="i-lucide-briefcase-business"
            title=""
            :description="$t('CRM.DEALS.EMPTY_DESCRIPTION')"
            :action-label="canManageDeals ? $t('CRM.DEALS.NEW_DEAL') : ''"
            @action="openCreateDrawer"
          />

          <div
            v-else-if="currentPresentation === 'list'"
            class="mt-3 overflow-hidden rounded-xl outline outline-1 outline-n-container"
          >
            <SchedulingRecordTable
              borderless
              class="crm-deal-list-table !rounded-none !bg-transparent"
              :columns="tableColumns"
              :rows="paginatedListDeals"
              :row-class="dealListRowClass"
              :sort-state="listSort"
              @sort="handleListSortChange"
            >
              <template #empty>
                {{
                  hasListSearchQuery
                    ? $t('CRM.DEALS.LIST.EMPTY_FILTERED')
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
                        canManageDeals &&
                        Number(editingDealTitleId) === Number(row.id)
                      "
                      autofocus
                      size="sm"
                      class="min-w-[14rem] flex-1"
                      :disabled="savingDealTitleId === row.id"
                      :model-value="dealTitleDraft"
                      custom-input-class="font-medium shadow-none !bg-n-surface-1"
                      @update:model-value="dealTitleDraft = $event"
                      @blur="saveDealTitle(row)"
                      @enter="saveDealTitle(row)"
                    />
                    <button
                      v-else
                      type="button"
                      class="min-w-0 max-w-full border-0 bg-transparent p-0 text-left"
                      @click="
                        canManageDeals
                          ? startEditingDealTitle(row)
                          : openEditDrawer(row)
                      "
                    >
                      <span class="font-medium text-n-slate-12">
                        {{ row.title }}
                      </span>
                    </button>
                    <span
                      v-if="row.company?.name"
                      class="rounded-md border border-n-weak bg-n-surface-1 px-1.5 py-0.5 text-[10px] font-medium text-n-slate-11"
                    >
                      {{ row.company.name }}
                    </span>
                    <span
                      v-if="row.primaryContact?.name"
                      class="rounded-md border border-n-weak bg-n-surface-1 px-1.5 py-0.5 text-[10px] font-medium text-n-slate-11"
                    >
                      {{ row.primaryContact.name }}
                    </span>
                    <span
                      v-if="row.archivedAt"
                      class="rounded-md bg-n-amber-9/10 px-1.5 py-0.5 text-[10px] font-medium text-n-amber-11"
                    >
                      {{ $t('CRM.GENERAL.ARCHIVED') }}
                    </span>
                  </span>
                  <CrmCustomFieldsSummary
                    :definitions="dealFieldDefinitions"
                    :values="row.customAttributes"
                  />
                </div>
              </template>

              <template #cell-stage="{ row }">
                <CrmDealStageMenu
                  v-if="canManageDeals"
                  :model-value="row.stageId"
                  :stages="listStageOptionsForDeal(row)"
                  @update:model-value="
                    handleDealStageChange({ deal: row, stageId: $event })
                  "
                />
                <span
                  v-else
                  class="inline-flex items-center gap-2 text-sm text-n-slate-12"
                >
                  <span
                    class="size-2.5 shrink-0 rounded-full outline outline-1 outline-black/10 dark:outline-white/10"
                    :style="{
                      backgroundColor:
                        stageColorById[row.stageId] || DEFAULT_STAGE_COLOR,
                    }"
                  />
                  {{
                    stageNameById[row.stageId] || $t('CRM.GENERAL.EMPTY_VALUE')
                  }}
                </span>
              </template>

              <template #cell-owner="{ row }">
                <CrmDealOwnerMenu
                  v-if="canManageDeals"
                  :model-value="row.ownerId"
                  :owners="ownerOptions"
                  @update:model-value="
                    handleDealOwnerChange({ deal: row, ownerId: $event })
                  "
                />
                <span v-else class="text-sm text-n-slate-12">
                  {{
                    ownerNameById[row.ownerId] || $t('CRM.GENERAL.EMPTY_VALUE')
                  }}
                </span>
              </template>

              <template #cell-amount="{ row }">
                <span
                  class="block w-full text-right text-sm tabular-nums text-n-slate-12"
                >
                  {{ formatDealAmountLabel(row) }}
                </span>
              </template>

              <template #cell-updatedAt="{ row }">
                <span class="text-sm text-n-slate-12">
                  {{ formatDate(row.updatedAt) }}
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
                    v-if="canManageDeals"
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
              :total-items="sortedListDeals.length"
              :items-per-page="LIST_PAGE_SIZE"
              @update:current-page="listCurrentPage = $event"
            />
          </div>
        </div>
      </div>
    </div>

    <Transition
      enter-active-class="transition-opacity duration-200 ease-out"
      enter-from-class="opacity-0"
      enter-to-class="opacity-100"
      leave-active-class="transition-opacity duration-150 ease-in"
      leave-from-class="opacity-100"
      leave-to-class="opacity-0"
    >
      <div
        v-if="drawerOpen"
        class="modal-mask fixed inset-0 z-[110] bg-black/35 p-3 backdrop-blur-[4px]"
      >
        <div :class="drawerModalClass">
          <aside
            class="flex h-full w-full flex-col overflow-hidden bg-n-solid-2 md:w-[28rem] md:min-w-[28rem] xl:w-[30rem] xl:min-w-[30rem]"
            :class="{
              'md:border-r md:border-n-weak': showLinkedConversationPanel,
            }"
          >
            <header
              class="flex items-center gap-2 border-b border-n-weak bg-n-surface-1 px-4 py-2"
            >
              <input
                id="crm-deal-drawer-title"
                class="reset-base min-w-0 flex-1 border-none bg-transparent text-base font-semibold text-n-slate-12 outline-none placeholder:text-n-slate-10"
                :aria-label="$t('CRM.DEALS.FORM.TITLE')"
                :placeholder="
                  selectedDeal
                    ? $t('CRM.DEALS.FORM.TITLE')
                    : $t('CRM.DEALS.CREATE_TITLE')
                "
                :readonly="!canManageDeals"
                :value="form.title"
                @input="form.title = $event.target.value"
              />

              <Button
                v-if="selectedDeal && canManageTasks"
                v-tooltip.top="$t('CRM.DEALS.CREATE_TASK')"
                size="sm"
                color="slate"
                variant="ghost"
                icon="i-lucide-list-plus"
                @click="openCreateTaskForDeal(selectedDeal)"
              />
              <Button
                v-if="selectedDeal && canManageDeals"
                v-tooltip.top="archiveTooltip"
                size="sm"
                color="slate"
                variant="ghost"
                :icon="
                  selectedDeal.archivedAt
                    ? 'i-lucide-archive-restore'
                    : 'i-lucide-archive'
                "
                @click="toggleArchived(selectedDeal)"
              />
              <Button
                v-if="canManageDeals && shouldShowDealSaveAction"
                size="sm"
                :is-loading="ui.isSaving"
                :disabled="disableDealSave"
                :label="
                  selectedDeal
                    ? $t('CRM.GENERAL.SAVE')
                    : $t('CRM.GENERAL.CREATE')
                "
                @click="saveDeal"
              />
              <Button
                size="sm"
                color="slate"
                variant="ghost"
                icon="i-lucide-x"
                @click="closeDrawer"
              />
            </header>

            <div class="min-h-0 flex-1 overflow-y-auto px-4 py-3">
              <div class="crm-deal-drawer-form">
                <div
                  class="crm-deal-drawer-section crm-deal-drawer-section--top"
                >
                  <div class="crm-deal-drawer-status-grid">
                    <SchedulingSelectField
                      id="crm-deal-drawer-pipeline"
                      class="crm-deal-drawer-control crm-deal-drawer-select-control"
                      :aria-label="$t('CRM.DEALS.FORM.PIPELINE')"
                      :disabled="!canManageDeals"
                      :model-value="form.pipelineId"
                      :options="pipelineOptions"
                      :placeholder="$t('CRM.DEALS.FORM.PIPELINE')"
                      dropdown-placement="auto"
                      @update:model-value="form.pipelineId = $event"
                    />
                    <SchedulingSelectField
                      id="crm-deal-drawer-stage"
                      class="crm-deal-drawer-control crm-deal-drawer-select-control"
                      :aria-label="$t('CRM.DEALS.FORM.STAGE')"
                      :disabled="!canManageDeals"
                      :model-value="form.stageId"
                      :options="stageOptions"
                      :placeholder="$t('CRM.DEALS.FORM.STAGE')"
                      dropdown-placement="auto"
                      @update:model-value="form.stageId = $event"
                    />
                    <SchedulingSelectField
                      id="crm-deal-drawer-owner"
                      class="crm-deal-drawer-control crm-deal-drawer-select-control"
                      :aria-label="$t('CRM.DEALS.FORM.OWNER')"
                      :disabled="!canManageDeals"
                      :model-value="form.ownerId"
                      :options="ownerOptions"
                      :placeholder="$t('CRM.DEALS.FORM.OWNER')"
                      dropdown-placement="auto"
                      @update:model-value="form.ownerId = $event"
                    />
                  </div>

                  <div v-if="shouldShowTeamField" class="crm-deal-drawer-row">
                    <label
                      class="crm-deal-drawer-label"
                      for="crm-deal-drawer-team"
                    >
                      {{ $t('CRM.DEALS.FORM.TEAM') }}
                    </label>
                    <SchedulingSelectField
                      id="crm-deal-drawer-team"
                      class="crm-deal-drawer-control crm-deal-drawer-select-control"
                      :aria-label="$t('CRM.DEALS.FORM.TEAM')"
                      :disabled="!canManageDeals"
                      :model-value="form.teamId"
                      :options="teamOptions"
                      :placeholder="$t('CRM.DEALS.FORM.TEAM')"
                      dropdown-placement="auto"
                      @update:model-value="form.teamId = $event"
                    />
                  </div>

                  <div class="crm-deal-drawer-inline-row">
                    <div class="crm-deal-drawer-inline-field">
                      <span class="crm-deal-drawer-label">
                        {{ $t('CRM.DEALS.FORM.EXPECTED_CLOSE_ON') }}
                      </span>
                      <SchedulingDateTimeField
                        class="crm-deal-drawer-control"
                        :aria-label="$t('CRM.DEALS.FORM.EXPECTED_CLOSE_ON')"
                        :model-value="form.expectedCloseOn"
                        :placeholder="$t('CRM.DEALS.FORM.EXPECTED_CLOSE_ON')"
                        type="date"
                        @update:model-value="form.expectedCloseOn = $event"
                      />
                    </div>

                    <div class="crm-deal-drawer-inline-field">
                      <label
                        class="crm-deal-drawer-label"
                        for="crm-deal-drawer-amount"
                      >
                        {{ $t('CRM.DEALS.FORM.AMOUNT') }}
                      </label>
                      <div
                        class="crm-deal-drawer-control crm-deal-drawer-amount-control"
                      >
                        <SchedulingCurrencyAmountInput
                          id="crm-deal-drawer-amount"
                          v-model:amount="form.amount"
                          v-model:currency="form.currency"
                          :aria-label="$t('CRM.DEALS.FORM.AMOUNT')"
                          :currencies="dealCurrencyOptions"
                          :currency-aria-label="$t('CRM.DEALS.FORM.CURRENCY')"
                          size="sm"
                          step="1"
                        />
                      </div>
                    </div>
                  </div>
                </div>

                <div class="crm-deal-drawer-section">
                  <div class="crm-deal-drawer-row crm-deal-drawer-row--start">
                    <div
                      class="crm-deal-drawer-label crm-deal-drawer-label-action"
                    >
                      <label for="crm-deal-drawer-contacts">
                        {{ $t('CRM.DEALS.FORM.CONTACTS') }}
                      </label>
                      <Button
                        v-if="canManageDeals"
                        v-tooltip.top="$t('CRM.DEALS.FORM.CREATE_CONTACT')"
                        class="crm-deal-drawer-label-button"
                        size="sm"
                        color="slate"
                        variant="ghost"
                        icon="i-lucide-plus"
                        @click="openCreateNewContactDialog"
                      />
                    </div>
                    <TagMultiSelectComboBox
                      id="crm-deal-drawer-contacts"
                      class="crm-deal-drawer-control crm-deal-drawer-multi-control"
                      :aria-label="$t('CRM.DEALS.FORM.CONTACTS')"
                      :disabled="!canManageDeals"
                      :model-value="form.contactIds"
                      :options="contactOptions"
                      :placeholder="$t('CRM.DEALS.FORM.CONTACTS')"
                      use-api-results
                      dropdown-placement="auto"
                      :search-placeholder="
                        $t('CRM.DEALS.FORM.CONTACTS_SEARCH_PLACEHOLDER')
                      "
                      :empty-state="$t('CRM.DEALS.FORM.CONTACTS_EMPTY_STATE')"
                      @open="loadContacts('')"
                      @search="loadContacts"
                      @update:model-value="form.contactIds = $event"
                    />
                  </div>

                  <div
                    v-if="shouldShowPrimaryContactSelect"
                    class="crm-deal-drawer-row"
                  >
                    <label
                      class="crm-deal-drawer-label"
                      for="crm-deal-drawer-primary-contact"
                    >
                      {{ $t('CRM.DEALS.FORM.PRIMARY_CONTACT') }}
                    </label>
                    <SchedulingSelectField
                      id="crm-deal-drawer-primary-contact"
                      class="crm-deal-drawer-control crm-deal-drawer-select-control"
                      :aria-label="$t('CRM.DEALS.FORM.PRIMARY_CONTACT')"
                      :disabled="!canManageDeals"
                      :model-value="form.primaryContactId"
                      dropdown-placement="auto"
                      :options="primaryContactOptions"
                      :placeholder="$t('CRM.DEALS.FORM.PRIMARY_CONTACT')"
                      @open="loadContacts('')"
                      @search="loadContacts"
                      @update:model-value="form.primaryContactId = $event"
                    />
                  </div>

                  <div v-if="companiesEnabled" class="crm-deal-drawer-row">
                    <div
                      class="crm-deal-drawer-label crm-deal-drawer-label-action"
                    >
                      <label for="crm-deal-drawer-company">
                        {{ $t('CRM.DEALS.FORM.COMPANY') }}
                      </label>
                      <Button
                        v-if="canManageDeals"
                        v-tooltip.top="$t('CRM.DEALS.FORM.CREATE_COMPANY')"
                        class="crm-deal-drawer-label-button"
                        size="sm"
                        color="slate"
                        variant="ghost"
                        icon="i-lucide-plus"
                        @click="openCreateCompanyDialog"
                      />
                    </div>
                    <SchedulingSelectField
                      id="crm-deal-drawer-company"
                      class="crm-deal-drawer-control crm-deal-drawer-select-control"
                      :aria-label="$t('CRM.DEALS.FORM.COMPANY')"
                      :disabled="!canManageDeals"
                      :model-value="form.companyId"
                      dropdown-placement="auto"
                      :options="companyOptions"
                      :placeholder="$t('CRM.DEALS.FORM.COMPANY')"
                      use-api-results
                      @open="loadCompanies('')"
                      @search="loadCompanies"
                      @update:model-value="form.companyId = $event"
                    />
                  </div>
                </div>

                <CrmCustomFieldsSection
                  :definitions="dealFieldDefinitions"
                  :framed="false"
                  layout="rows"
                  :model-value="form.customAttributes"
                  @update:model-value="form.customAttributes = $event"
                />

                <div class="crm-deal-drawer-section">
                  <div class="crm-deal-drawer-row crm-deal-drawer-row--start">
                    <label
                      class="crm-deal-drawer-label"
                      for="crm-deal-drawer-description"
                    >
                      {{ $t('CRM.DEALS.FORM.DESCRIPTION') }}
                    </label>
                    <TextArea
                      id="crm-deal-drawer-description"
                      class="crm-deal-drawer-control"
                      :aria-label="$t('CRM.DEALS.FORM.DESCRIPTION')"
                      :model-value="form.description"
                      auto-height
                      custom-text-area-wrapper-class="!rounded-md !border-n-weak !bg-n-alpha-black2 !px-2 !py-1 hover:!border-n-slate-6"
                      min-height="3rem"
                      max-height="none"
                      @update:model-value="form.description = $event"
                    />
                  </div>
                </div>

                <CrmTimelineFeed
                  v-if="selectedDeal"
                  :items="timelineItems"
                  :is-loading="ui.isTimelineLoading"
                  :is-saving-comment="ui.isSavingComment"
                  :can-manage-comments="canManageDeals"
                  :empty-message="$t('CRM.TIMELINE.EMPTY')"
                  @create-comment="saveComment"
                  @delete-comment="deleteComment"
                />
              </div>
            </div>
          </aside>

          <CrmDealConversationPanel
            :communication-thread-id="linkedCommunicationThreadId"
            :communication-thread-display-id="
              linkedCommunicationThreadDisplayId
            "
            :conversation-id="linkedConversationId"
            :conversation-display-id="linkedConversationDisplayId"
            :visible="drawerOpen && showLinkedConversationPanel"
            @close="showLinkedConversationPanel = false"
          />
        </div>
      </div>
    </Transition>

    <CrmClosingReasonDialog ref="closingReasonDialogRef" />

    <CreateNewContactDialog
      ref="createNewContactDialogRef"
      @create="createContact"
    />
    <CreateCompanyDialog ref="createCompanyDialogRef" @create="createCompany" />

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
          :label="$t('CRM.DEALS.FORM.OWNER')"
          :model-value="filterDraft.ownerId"
          :options="ownerOptions"
          :placeholder="$t('CRM.DEALS.FORM.OWNER')"
          @update:model-value="filterDraft.ownerId = $event"
        />

        <SchedulingSelectField
          :label="$t('CRM.DEALS.FORM.STAGE')"
          :model-value="filterDraft.stageId"
          :options="filterStageOptions"
          :placeholder="$t('CRM.DEALS.FORM.STAGE')"
          @update:model-value="filterDraft.stageId = $event"
        />

        <SchedulingSelectField
          v-if="shouldShowTeamField"
          :label="$t('CRM.DEALS.FORM.TEAM')"
          :model-value="filterDraft.teamId"
          :options="teamOptions"
          :placeholder="$t('CRM.DEALS.FORM.TEAM')"
          @update:model-value="filterDraft.teamId = $event"
        />

        <SchedulingSelectField
          v-if="companiesEnabled"
          :label="$t('CRM.DEALS.FORM.COMPANY')"
          :model-value="filterDraft.companyId"
          :options="companyOptions"
          use-api-results
          :placeholder="$t('CRM.DEALS.FORM.COMPANY')"
          @open="loadCompanies('')"
          @search="loadCompanies"
          @update:model-value="filterDraft.companyId = $event"
        />

        <SchedulingSelectField
          :label="$t('CRM.DEALS.FORM.PRIMARY_CONTACT')"
          :model-value="filterDraft.contactId"
          :options="contactOptions"
          use-api-results
          :placeholder="$t('CRM.DEALS.FORM.PRIMARY_CONTACT')"
          :search-placeholder="$t('CRM.DEALS.FORM.CONTACTS_SEARCH_PLACEHOLDER')"
          :empty-state="$t('CRM.DEALS.FORM.CONTACTS_EMPTY_STATE')"
          @open="loadContacts('')"
          @search="loadContacts"
          @update:model-value="filterDraft.contactId = $event"
        />

        <SchedulingMultiSelectFilter
          v-for="definition in discreteDealFieldDefinitions"
          :key="definition.key"
          :model-value="customFieldFilterDraft[definition.key] || []"
          :options="customFieldFilterOptions(definition)"
          :placeholder="definition.label"
          :show-trigger-icon="false"
          @update:model-value="
            updateDealCustomFieldFilterDraft(definition.key, $event)
          "
        />

        <SchedulingCustomFieldAdvancedFilter
          v-for="definition in advancedDealFieldDefinitions"
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
            updateDealCustomFieldFilterDraft(definition.key, $event)
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
.crm-deal-drawer-form {
  @apply grid gap-3;
}

.crm-deal-drawer-section {
  @apply grid gap-2 border-t border-n-weak pt-3;
}

.crm-deal-drawer-section:first-of-type {
  @apply border-t-0 pt-0;
}

.crm-deal-drawer-status-grid {
  @apply grid gap-2 md:grid-cols-3;
}

.crm-deal-drawer-status-grid :deep(button) {
  @apply min-w-0;
}

.crm-deal-drawer-row,
.crm-deal-drawer-inline-row,
.crm-deal-drawer-inline-field {
  display: grid;
  gap: 0.375rem;
  min-width: 0;
}

.crm-deal-drawer-inline-row {
  align-items: end;
  column-gap: 1.5rem;
  grid-template-columns: minmax(0, 1fr) minmax(0, 1.15fr);
}

.crm-deal-drawer-label {
  @apply mb-0 min-w-0 text-[13px] font-medium leading-4 text-n-slate-12;
}

.crm-deal-drawer-label-action {
  @apply flex items-center justify-between gap-2;
}

.crm-deal-drawer-label-button {
  flex-shrink: 0;
  height: 1.75rem !important;
  width: 1.75rem !important;
}

.crm-deal-drawer-control,
.crm-deal-drawer-form :deep(.crm-deal-drawer-control) {
  width: 100%;
  min-width: 0;
}

.crm-deal-drawer-form :deep(.crm-deal-drawer-control input),
.crm-deal-drawer-form :deep(.crm-deal-drawer-control select),
.crm-deal-drawer-form
  :deep(.crm-deal-drawer-control .reka-date-time-picker__trigger),
.crm-deal-drawer-form :deep(.crm-deal-drawer-multi-control button),
.crm-deal-drawer-form :deep(.crm-deal-drawer-select-control button) {
  @apply border border-n-weak bg-n-alpha-black2 text-sm font-normal text-n-slate-12 shadow-none outline outline-1 outline-transparent transition-colors duration-150 !important;
  border-radius: 0.375rem !important;
  min-height: 2rem !important;
}

.crm-deal-drawer-form :deep(.crm-deal-drawer-control input),
.crm-deal-drawer-form :deep(.crm-deal-drawer-control select),
.crm-deal-drawer-form
  :deep(.crm-deal-drawer-control .reka-date-time-picker__trigger),
.crm-deal-drawer-form :deep(.crm-deal-drawer-select-control button) {
  height: 2rem !important;
}

.crm-deal-drawer-form
  :deep(.crm-deal-drawer-control:not(.crm-deal-drawer-amount-control) input) {
  @apply px-2 py-1 !important;
}

.crm-deal-drawer-form :deep(.crm-deal-drawer-amount-control input) {
  @apply py-1 pr-2 !important;
  border-bottom-right-radius: 0 !important;
  border-top-right-radius: 0 !important;
  padding-left: 2rem !important;
}

.crm-deal-drawer-form :deep(.crm-deal-drawer-amount-control select) {
  border-bottom-left-radius: 0 !important;
  border-top-left-radius: 0 !important;
}

.crm-deal-drawer-form
  :deep(.crm-deal-drawer-control .reka-date-time-picker__trigger),
.crm-deal-drawer-form :deep(.crm-deal-drawer-multi-control button),
.crm-deal-drawer-form :deep(.crm-deal-drawer-select-control button) {
  @apply justify-start py-1 !important;
}

.crm-deal-drawer-form :deep(.crm-deal-drawer-control input:hover),
.crm-deal-drawer-form :deep(.crm-deal-drawer-control select:hover),
.crm-deal-drawer-form
  :deep(.crm-deal-drawer-control .reka-date-time-picker__trigger:hover),
.crm-deal-drawer-form :deep(.crm-deal-drawer-multi-control button:hover),
.crm-deal-drawer-form :deep(.crm-deal-drawer-select-control button:hover) {
  @apply border-n-slate-6 bg-n-alpha-black2 outline-transparent !important;
}

.crm-deal-drawer-form :deep(.crm-deal-drawer-control input:focus),
.crm-deal-drawer-form :deep(.crm-deal-drawer-control select:focus),
.crm-deal-drawer-form
  :deep(.crm-deal-drawer-control .reka-date-time-picker__trigger:focus),
.crm-deal-drawer-form
  :deep(
    .crm-deal-drawer-control .reka-date-time-picker__trigger[data-state='open']
  ),
.crm-deal-drawer-form :deep(.crm-deal-drawer-multi-control button:focus),
.crm-deal-drawer-form
  :deep(.crm-deal-drawer-multi-control button[data-state='open']),
.crm-deal-drawer-form :deep(.crm-deal-drawer-select-control button:focus),
.crm-deal-drawer-form
  :deep(.crm-deal-drawer-select-control button[data-state='open']) {
  @apply border-n-weak bg-n-alpha-black2 outline-n-brand !important;
}

.crm-deal-drawer-form :deep(.crm-deal-drawer-control textarea) {
  @apply text-sm font-normal text-n-slate-12 !important;
}

.crm-deal-drawer-form :deep(.crm-deal-drawer-multi-control button) {
  height: auto !important;
  min-height: 2rem !important;
}

.crm-deal-drawer-form :deep(.crm-deal-drawer-multi-control button > div) {
  @apply max-w-[75%] rounded-md border border-n-blue-4/40 bg-n-blue-3/60 px-1.5 py-0.5 text-n-blue-11 !important;
}

.crm-deal-drawer-form :deep(.crm-deal-drawer-multi-control button > div span) {
  @apply text-n-blue-11 !important;
}

@media (min-width: 768px) {
  .crm-deal-drawer-row {
    align-items: center;
    grid-template-columns: minmax(6.5rem, 1fr) minmax(8rem, 14rem);
  }

  .crm-deal-drawer-row--wide-control {
    grid-template-columns: minmax(4.5rem, 1fr) minmax(10rem, 18rem);
  }

  .crm-deal-drawer-row--start {
    align-items: start;
  }

  .crm-deal-drawer-label {
    @apply text-left;
  }

  .crm-deal-drawer-row--start > .crm-deal-drawer-label,
  .crm-deal-drawer-row--start > .crm-deal-drawer-label-action {
    padding-top: 0.5rem;
  }

  .crm-deal-drawer-label-action {
    @apply justify-start;
  }
}

.crm-deal-list-table :deep(.grid.border-b) {
  @apply bg-n-surface-1/70;
  padding-top: 0.625rem;
  padding-bottom: 0.625rem;
}

.crm-deal-list-table :deep(.divide-y > .grid) {
  gap: 0.5rem;
  padding-top: 0.5rem;
  padding-bottom: 0.5rem;
}
</style>
