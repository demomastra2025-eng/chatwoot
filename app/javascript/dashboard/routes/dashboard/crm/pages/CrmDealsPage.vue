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
import {
  CRM_DEAL_MANAGE_PERMISSION,
  CRM_DEAL_VIEW_PERMISSION,
} from 'dashboard/constants/permissions';
import { FEATURE_FLAGS } from 'dashboard/featureFlags';
import Button from 'dashboard/components-next/button/Button.vue';
import Checkbox from 'dashboard/components-next/checkbox/Checkbox.vue';
import Dialog from 'dashboard/components-next/dialog/Dialog.vue';
import Icon from 'dashboard/components-next/icon/Icon.vue';
import Input from 'dashboard/components-next/input/Input.vue';
import Spinner from 'dashboard/components-next/spinner/Spinner.vue';
import TextArea from 'dashboard/components-next/textarea/TextArea.vue';
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
import SchedulingSidePanel from 'dashboard/components-next/Scheduling/SchedulingSidePanel.vue';
import SchedulingEmptyState from 'dashboard/components-next/Scheduling/SchedulingEmptyState.vue';
import SchedulingErrorState from 'dashboard/components-next/Scheduling/SchedulingErrorState.vue';
import SchedulingFormFieldGroup from 'dashboard/components-next/Scheduling/SchedulingFormFieldGroup.vue';
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
  currency: '',
  customAttributes: {},
  description: '',
  expectedCloseOn: '',
  externalRef: '',
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
  checkPermissions(['administrator', CRM_DEAL_MANAGE_PERMISSION])
);
const canViewDeals = computed(() =>
  checkPermissions([
    'administrator',
    'agent',
    CRM_DEAL_VIEW_PERMISSION,
    CRM_DEAL_MANAGE_PERMISSION,
  ])
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
const canOpenLinkedConversation = computed(
  () => !!linkedConversationId.value || !!linkedConversationDisplayId.value
);
const archiveTooltip = computed(() =>
  selectedDeal.value?.archivedAt
    ? t('CRM.GENERAL.UNARCHIVE')
    : t('CRM.GENERAL.ARCHIVE')
);

const activePipelines = computed(() =>
  referencesStore.pipelines.filter(pipeline => pipeline.active !== false)
);

const pipelineOptions = computed(() =>
  referencesStore.pipelines.map(pipeline => ({
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
    value: stage.id,
  }))
);

const ownerOptions = computed(() =>
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

const filterStageOptions = computed(() => {
  const pipelineId = resolvePipelineFilterId(
    filterDraft.pipelineId || filters.pipelineId
  );
  const pipeline = activePipelines.value.find(
    item => Number(item.id) === Number(pipelineId)
  );

  return (pipeline?.stages || []).map(stage => ({
    label: stage.name,
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
    label: [primaryLabel, secondaryLabel].filter(Boolean).join(' · '),
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

const resetForm = () => {
  const defaultPipelineId = resolvePipelineFilterId(filters.pipelineId);
  const resolvedDefaultPipeline =
    referencesStore.pipelines.find(
      pipeline => Number(pipeline.id) === Number(defaultPipelineId)
    ) ||
    referencesStore.pipelines.find(pipeline => pipeline.default) ||
    referencesStore.pipelines[0];
  const defaultStage = resolvedDefaultPipeline?.stages?.[0];

  Object.assign(form, {
    amount: 0,
    companyId: '',
    contactIds: [],
    currency: defaultDealCurrency,
    customAttributes: buildDefaultCustomAttributes(dealFieldDefinitions.value),
    description: '',
    expectedCloseOn: '',
    externalRef: '',
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
    currency: deal.currency || defaultDealCurrency,
    customAttributes: { ...(deal.customAttributes || {}) },
    description: deal.description || '',
    expectedCloseOn: deal.expectedCloseOn
      ? deal.expectedCloseOn.slice(0, 10)
      : '',
    externalRef: deal.externalRef || '',
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
  'conversationDisplayId',
  'currency',
  'dealId',
  'description',
  'expectedCloseOn',
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
  }
};

const openEditDrawer = async deal => {
  closeDealTitleEditor();
  pendingCreateCustomFieldDefaultsHydration.value = false;
  selectedDeal.value = deal;
  populateFormFromDeal(deal);
  drawerOpen.value = true;
  showLinkedConversationPanel.value = false;
  await Promise.all([loadContacts(''), loadCompanies('')]);
  await ensureSelectedLookups(deal);
  await loadTimeline(deal.id);
};

const closeDrawer = () => {
  closeDealTitleEditor();
  pendingCreateCustomFieldDefaultsHydration.value = false;
  drawerOpen.value = false;
  showLinkedConversationPanel.value = false;
  selectedDeal.value = null;
  timelineItems.value = [];
  resetForm();
};

const toggleLinkedConversationPanel = () => {
  if (!canOpenLinkedConversation.value) {
    return;
  }

  showLinkedConversationPanel.value = !showLinkedConversationPanel.value;
};

const openCreateNewContactDialog = () => {
  createNewContactDialogRef.value?.dialogRef.open();
};

const openCreateCompanyDialog = () => {
  createCompanyDialogRef.value?.dialogRef?.open();
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
    currency: form.currency || undefined,
    custom_attributes: form.customAttributes,
    description: form.description || undefined,
    expected_close_on: form.expectedCloseOn || undefined,
    external_ref: form.externalRef || undefined,
    lock_version: selectedDeal.value?.lockVersion,
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
  ui.isSaving = true;

  try {
    const wasEditingDeal = !!selectedDeal.value;
    const payload = buildPayload();
    let deal;

    if (selectedDeal.value) {
      const currentStageId = selectedDeal.value.stageId;
      const { stage_id: _stageId, ...updatePayload } = payload;
      const response = await CrmDealsAPI.update(
        selectedDeal.value.id,
        updatePayload
      );
      deal = normalizePayload(response.data);

      if (Number(form.stageId) !== Number(currentStageId) && form.stageId) {
        const transitionResponse = await CrmDealsAPI.transitionStage(deal.id, {
          lock_version: deal.lockVersion,
          stage_id: Number(form.stageId),
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

  if (
    selectedDeal.value &&
    Number(selectedDeal.value.id) === Number(currentDeal.id)
  ) {
    selectedDeal.value = {
      ...selectedDeal.value,
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
            lock_version: currentDeal.lockVersion,
            position: nextPosition || undefined,
            stage_id: nextStageId,
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

  const contactId = numericQueryValue('contactId');
  const companyId = numericQueryValue('companyId');

  await openCreateDrawer({
    amount: decimalQueryValue('amount') || 0,
    companyId,
    contactIds: contactId ? [contactId] : [],
    currency: queryValue('currency') || defaultDealCurrency,
    description: queryValue('description') || '',
    expectedCloseOn: queryValue('expectedCloseOn') || '',
    originatingConversationDisplayId: queryValue('conversationDisplayId')
      ? `#${queryValue('conversationDisplayId')}`
      : '',
    originatingConversationId: numericQueryValue('originatingConversationId'),
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
    const firstStage = pipeline?.stages?.[0];

    if (
      !pipeline?.stages?.some(
        stage => Number(stage.id) === Number(form.stageId)
      )
    ) {
      form.stageId = firstStage?.id || '';
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

watch(linkedConversationId, conversationId => {
  if (!conversationId) {
    showLinkedConversationPanel.value = false;
  }
});

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

onMounted(async () => {
  if (!canViewDeals.value) return;

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
  resetForm();
  hasRestoredPreferences.value = true;
  persistDealsPreferences();
  await loadDeals();
  if (await consumeDealOpenQuery()) return;
  await consumeDealPrefillQuery();
});
</script>

<template>
  <section class="relative flex flex-1 min-h-0 overflow-hidden bg-n-slate-2">
    <div class="flex min-w-0 flex-1 flex-col overflow-hidden">
      <SchedulingPageHeader
        class="!bg-n-slate-2"
        :title="$t('CRM.DEALS.TITLE')"
      >
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
            variant="outline"
            icon="i-lucide-filter"
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

    <CrmDealConversationPanel
      :conversation-id="linkedConversationId"
      :conversation-display-id="linkedConversationDisplayId"
      :visible="drawerOpen && showLinkedConversationPanel"
      @close="showLinkedConversationPanel = false"
    />

    <SchedulingSidePanel
      v-model="drawerOpen"
      :close-on-click-outside="false"
      width="xs"
      :title="
        selectedDeal ? $t('CRM.DEALS.EDIT_TITLE') : $t('CRM.DEALS.CREATE_TITLE')
      "
      :description="$t('CRM.DEALS.DRAWER_DESCRIPTION')"
      :confirm-label="
        selectedDeal ? $t('CRM.GENERAL.SAVE') : $t('CRM.GENERAL.CREATE')
      "
      :is-loading="ui.isSaving"
      :disable-confirm="!form.title.trim() || !form.pipelineId || !form.stageId"
      @close="closeDrawer"
      @confirm="saveDeal"
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
              :label="$t('CRM.DEALS.FORM.TITLE')"
              :model-value="form.title"
              @update:model-value="form.title = $event"
            />
            <SchedulingSelectField
              v-if="selectedDeal"
              :label="$t('CRM.DEALS.FORM.PIPELINE')"
              :model-value="form.pipelineId"
              :options="pipelineOptions"
              @update:model-value="form.pipelineId = $event"
            />
            <SchedulingSelectField
              :label="$t('CRM.DEALS.FORM.STAGE')"
              :model-value="form.stageId"
              :options="stageOptions"
              @update:model-value="form.stageId = $event"
            />
            <SchedulingSelectField
              :label="$t('CRM.DEALS.FORM.OWNER')"
              :model-value="form.ownerId"
              :options="ownerOptions"
              @update:model-value="form.ownerId = $event"
            />
            <SchedulingSelectField
              :label="$t('CRM.DEALS.FORM.TEAM')"
              :model-value="form.teamId"
              :options="teamOptions"
              @update:model-value="form.teamId = $event"
            />
            <SchedulingDateTimeField
              :label="$t('CRM.DEALS.FORM.EXPECTED_CLOSE_ON')"
              :model-value="form.expectedCloseOn"
              type="date"
              @update:model-value="form.expectedCloseOn = $event"
            />
            <SchedulingCurrencyAmountInput
              v-model:amount="form.amount"
              v-model:currency="form.currency"
              :currencies="dealCurrencyOptions"
              :currency-aria-label="$t('CRM.DEALS.FORM.CURRENCY')"
              step="1"
              :label="$t('CRM.DEALS.FORM.AMOUNT')"
            />
          </div>
        </SchedulingFormFieldGroup>

        <SchedulingFormFieldGroup :framed="false">
          <div class="grid gap-4 md:grid-cols-2">
            <div class="grid gap-1 md:col-span-2">
              <div class="mb-0.5 flex items-center justify-between gap-3">
                <span class="text-sm font-medium text-n-slate-12">
                  {{ $t('CRM.DEALS.FORM.CONTACTS') }}
                </span>
                <Button
                  size="sm"
                  color="blue"
                  variant="link"
                  icon="i-lucide-plus"
                  :label="$t('CRM.DEALS.FORM.CREATE_CONTACT')"
                  @click="openCreateNewContactDialog"
                />
              </div>
              <TagMultiSelectComboBox
                :model-value="form.contactIds"
                :options="contactOptions"
                use-api-results
                dropdown-placement="top"
                :search-placeholder="
                  $t('CRM.DEALS.FORM.CONTACTS_SEARCH_PLACEHOLDER')
                "
                :empty-state="$t('CRM.DEALS.FORM.CONTACTS_EMPTY_STATE')"
                @open="loadContacts('')"
                @search="loadContacts"
                @update:model-value="form.contactIds = $event"
              />
            </div>
            <SchedulingSelectField
              :label="$t('CRM.DEALS.FORM.PRIMARY_CONTACT')"
              :model-value="form.primaryContactId"
              dropdown-placement="top"
              :options="
                contactOptions.filter(option =>
                  form.contactIds.includes(option.value)
                )
              "
              @open="loadContacts('')"
              @search="loadContacts"
              @update:model-value="form.primaryContactId = $event"
            />
            <div v-if="companiesEnabled" class="grid gap-1">
              <div class="mb-0.5 flex items-center justify-between gap-3">
                <span class="text-sm font-medium text-n-slate-12">
                  {{ $t('CRM.DEALS.FORM.COMPANY') }}
                </span>
                <Button
                  size="sm"
                  color="blue"
                  variant="link"
                  icon="i-lucide-plus"
                  :label="$t('CRM.DEALS.FORM.CREATE_COMPANY')"
                  @click="openCreateCompanyDialog"
                />
              </div>
              <SchedulingSelectField
                :model-value="form.companyId"
                dropdown-placement="top"
                :options="companyOptions"
                use-api-results
                @open="loadCompanies('')"
                @search="loadCompanies"
                @update:model-value="form.companyId = $event"
              />
            </div>
          </div>
        </SchedulingFormFieldGroup>

        <CrmCustomFieldsSection
          :definitions="dealFieldDefinitions"
          :framed="false"
          :model-value="form.customAttributes"
          :title="$t('CRM.CUSTOM_FIELDS.TITLE')"
          :description="$t('CRM.CUSTOM_FIELDS.DESCRIPTION')"
          @update:model-value="form.customAttributes = $event"
        />

        <SchedulingFormFieldGroup :framed="false">
          <TextArea
            :label="$t('CRM.DEALS.FORM.DESCRIPTION')"
            :model-value="form.description"
            auto-height
            @update:model-value="form.description = $event"
          />
        </SchedulingFormFieldGroup>

        <SchedulingFormFieldGroup
          v-if="selectedDeal"
          :framed="false"
          :title="$t('CRM.TIMELINE.TITLE')"
          :description="$t('CRM.TIMELINE.DESCRIPTION')"
        >
          <CrmTimelineFeed
            :items="timelineItems"
            :is-loading="ui.isTimelineLoading"
            :is-saving-comment="ui.isSavingComment"
            :can-manage-comments="canManageDeals"
            :empty-message="$t('CRM.TIMELINE.EMPTY')"
            @create-comment="saveComment"
            @delete-comment="deleteComment"
          />
        </SchedulingFormFieldGroup>
      </div>

      <template v-if="canManageDeals" #footer>
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
              v-if="selectedDeal"
              v-tooltip.top="archiveTooltip"
              size="sm"
              color="slate"
              variant="outline"
              :icon="
                selectedDeal.archivedAt
                  ? 'i-lucide-archive-restore'
                  : 'i-lucide-archive'
              "
              @click="toggleArchived(selectedDeal)"
            />
            <Button
              v-if="canOpenLinkedConversation"
              size="sm"
              color="slate"
              variant="outline"
              icon="i-lucide-message-circle"
              :label="$t('CRM.GENERAL.CHAT')"
              @click="toggleLinkedConversationPanel"
            />
            <Button
              size="sm"
              :is-loading="ui.isSaving"
              :disabled="
                !form.title.trim() || !form.pipelineId || !form.stageId
              "
              :label="
                selectedDeal ? $t('CRM.GENERAL.SAVE') : $t('CRM.GENERAL.CREATE')
              "
              @click="saveDeal"
            />
          </div>
        </div>
      </template>
    </SchedulingSidePanel>

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
