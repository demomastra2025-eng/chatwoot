<script setup>
import { computed, onMounted, reactive, ref, watch } from 'vue';
import { format } from 'date-fns';
import { useI18n } from 'vue-i18n';
import { useRoute, useRouter } from 'vue-router';

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
import CrmCustomFieldsSection from 'dashboard/components-next/CRM/CrmCustomFieldsSection.vue';
import CrmDealBoard from 'dashboard/components-next/CRM/CrmDealBoard.vue';
import CrmTimelineFeed from 'dashboard/components-next/CRM/CrmTimelineFeed.vue';
import SchedulingDateTimeField from 'dashboard/components-next/Scheduling/SchedulingDateTimeField.vue';
import SchedulingDrawer from 'dashboard/components-next/Scheduling/SchedulingDrawer.vue';
import SchedulingCurrencyAmountInput from 'dashboard/components-next/Scheduling/SchedulingCurrencyAmountInput.vue';
import SchedulingEmptyState from 'dashboard/components-next/Scheduling/SchedulingEmptyState.vue';
import SchedulingErrorState from 'dashboard/components-next/Scheduling/SchedulingErrorState.vue';
import SchedulingFormFieldGroup from 'dashboard/components-next/Scheduling/SchedulingFormFieldGroup.vue';
import SchedulingPageHeader from 'dashboard/components-next/Scheduling/SchedulingPageHeader.vue';
import SchedulingRecordTable from 'dashboard/components-next/Scheduling/SchedulingRecordTable.vue';
import SchedulingSelectField from 'dashboard/components-next/Scheduling/SchedulingSelectField.vue';
import SchedulingViewSwitcher from 'dashboard/components-next/Scheduling/SchedulingViewSwitcher.vue';
import TagMultiSelectComboBox from 'dashboard/components-next/combobox/TagMultiSelectComboBox.vue';
import { useCrmReferencesStore } from 'dashboard/stores/crm/references';
import {
  compactPayload,
  formatCrmErrorMessage,
  normalizePayload,
} from 'dashboard/stores/crm/shared';

const referencesStore = useCrmReferencesStore();
const store = useStore();
const route = useRoute();
const router = useRouter();
const { checkPermissions } = usePolicy();
const { t } = useI18n();

const deals = ref([]);
const currentPresentation = ref('board');
const drawerOpen = ref(false);
const filterDialogRef = ref(null);
const timelineItems = ref([]);
const contactOptions = ref([]);
const companyOptions = ref([]);
const selectedDeal = ref(null);

const filters = reactive({
  archived: false,
  ownerId: '',
  pipelineId: '',
  q: '',
  teamId: '',
});
const filterDraft = reactive({
  archived: false,
  ownerId: '',
  pipelineId: '',
  q: '',
  teamId: '',
});

const form = reactive({
  amountMinor: '',
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
  isLoading: false,
  isSaving: false,
  isSavingComment: false,
  isTimelineLoading: false,
});

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

const pipelineOptions = computed(() =>
  referencesStore.pipelines.map(pipeline => ({
    label: pipeline.name,
    value: pipeline.id,
  }))
);

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
    value: agent.id,
  }))
);

const teamOptions = computed(() =>
  teams.value.map(team => ({
    label: team.name,
    value: team.id,
  }))
);

const boardStages = computed(() => {
  const pipelines = filters.pipelineId
    ? referencesStore.pipelines.filter(
        pipeline => Number(pipeline.id) === Number(filters.pipelineId)
      )
    : referencesStore.pipelines;

  return pipelines.flatMap(pipeline =>
    (pipeline.stages || []).map(stage => ({
      id: stage.id,
      label: stage.name,
      name: stage.name,
      pipelineName: pipeline.name,
    }))
  );
});

const viewOptions = computed(() => [
  { label: t('CRM.VIEWS.BOARD'), value: 'board' },
  { label: t('CRM.VIEWS.LIST'), value: 'list' },
]);

const tableColumns = computed(() => [
  { key: 'title', label: t('CRM.DEALS.TABLE.TITLE'), width: '1.8fr' },
  { key: 'stage', label: t('CRM.DEALS.TABLE.STAGE'), width: '1fr' },
  { key: 'owner', label: t('CRM.DEALS.TABLE.OWNER'), width: '1fr' },
  { key: 'amount', label: t('CRM.DEALS.TABLE.AMOUNT'), width: '0.8fr' },
  { key: 'updatedAt', label: t('CRM.DEALS.TABLE.UPDATED'), width: '0.9fr' },
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

const ownerNameById = computed(() =>
  agents.value.reduce((result, agent) => {
    result[agent.id] = agent.name || agent.email;
    return result;
  }, {})
);

const currentUserId = computed(() => {
  const userId = Number(currentUser.value?.id);
  return Number.isFinite(userId) && userId > 0 ? userId : '';
});

const defaultDealCurrency = 'KZT';
const dealCurrencyOptions = ['KZT', 'USD', 'EUR', 'RUB'];

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
  const defaultPipeline =
    referencesStore.pipelines.find(pipeline => pipeline.default) ||
    referencesStore.pipelines[0];
  const defaultStage = defaultPipeline?.stages?.[0];

  Object.assign(form, {
    amountMinor: '',
    companyId: '',
    contactIds: [],
    currency: defaultDealCurrency,
    customAttributes: defaultCustomAttributes(dealFieldDefinitions.value),
    description: '',
    expectedCloseOn: '',
    externalRef: '',
    originatingConversationDisplayId: '',
    originatingConversationId: '',
    ownerId: currentUserId.value,
    pipelineId: defaultPipeline?.id || '',
    primaryContactId: '',
    stageId: defaultStage?.id || '',
    teamId: '',
    title: '',
    winProbability: '',
  });
};

const formatErrorMessage = error => formatCrmErrorMessage(error, t);

const formatDate = value => {
  if (!value) return t('CRM.GENERAL.EMPTY_VALUE');
  return format(new Date(value), 'MMM d, yyyy');
};

const crmPrefillKeys = [
  'action',
  'companyId',
  'companyName',
  'contactId',
  'contactName',
  'conversationDisplayId',
  'originatingConversationId',
  'ownerId',
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

const loadContacts = async query => {
  const response = query
    ? await ContactAPI.search(query, 1)
    : await ContactAPI.get(1);
  contactOptions.value = normalizePayload(response.data).map(contact => ({
    label: [contact.name, contact.phoneNumber].filter(Boolean).join(' · '),
    value: contact.id,
  }));
};

const loadCompanies = async query => {
  if (!companiesEnabled.value) {
    companyOptions.value = [];
    return;
  }

  const response = query
    ? await CompanyAPI.search(query, 1)
    : await CompanyAPI.get();
  companyOptions.value = normalizePayload(response.data).map(company => ({
    label: company.name,
    value: company.id,
  }));
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
    contactOptions.value = [
      ...contactOptions.value,
      ...resolvedContacts.map(contact => ({
        label: [contact.name, contact.phoneNumber].filter(Boolean).join(' · '),
        value: contact.id,
      })),
    ];
  }

  if (missingCompanyId && companiesEnabled.value) {
    const response = await CompanyAPI.show(deal.companyId);
    const company = normalizePayload(response.data);
    companyOptions.value = [
      ...companyOptions.value,
      {
        label: company.name,
        value: company.id,
      },
    ];
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
  selectedDeal.value = null;
  resetForm();
  drawerOpen.value = true;
  timelineItems.value = [];
  await Promise.all([loadContacts(''), loadCompanies('')]);

  if (prefill) {
    Object.assign(form, prefill);
  }
};

const openEditDrawer = async deal => {
  selectedDeal.value = deal;
  Object.assign(form, {
    amountMinor: deal.amountMinor ?? '',
    companyId: deal.companyId ?? '',
    contactIds: (deal.dealContacts || []).map(contact => contact.contactId),
    currency: deal.currency || defaultDealCurrency,
    customAttributes: { ...(deal.customAttributes || {}) },
    description: deal.description || '',
    expectedCloseOn: deal.expectedCloseOn
      ? deal.expectedCloseOn.slice(0, 10)
      : '',
    externalRef: deal.externalRef || '',
    originatingConversationDisplayId: deal.originatingConversationId
      ? `#${deal.originatingConversationId}`
      : '',
    originatingConversationId: deal.originatingConversationId ?? '',
    ownerId: deal.ownerId ?? '',
    pipelineId: deal.pipelineId,
    primaryContactId: deal.primaryContactId ?? '',
    stageId: deal.stageId,
    teamId: deal.teamId ?? '',
    title: deal.title,
    winProbability: deal.winProbability ?? '',
  });
  drawerOpen.value = true;
  await Promise.all([loadContacts(''), loadCompanies('')]);
  await ensureSelectedLookups(deal);
  await loadTimeline(deal.id);
};

const closeDrawer = () => {
  drawerOpen.value = false;
  selectedDeal.value = null;
  timelineItems.value = [];
  resetForm();
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
    amount_minor:
      form.amountMinor === '' || form.amountMinor === null
        ? undefined
        : Number(form.amountMinor),
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
    useAlert(
      selectedDeal.value
        ? t('CRM.DEALS.SUCCESS_UPDATED')
        : t('CRM.DEALS.SUCCESS_CREATED')
    );
    closeDrawer();
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
    upsertDeal(normalizePayload(response.data));
    useAlert(
      deal.archivedAt
        ? t('CRM.DEALS.SUCCESS_UNARCHIVED')
        : t('CRM.DEALS.SUCCESS_ARCHIVED')
    );
  } catch (error) {
    useAlert(formatErrorMessage(error));
  }
};

const loadDeals = async () => {
  ui.isLoading = true;
  ui.error = null;

  try {
    const { data } = await CrmDealsAPI.get(
      compactPayload({
        archived: filters.archived,
        owner_id: filters.ownerId || undefined,
        pipeline_id: filters.pipelineId || undefined,
        q: filters.q || undefined,
        team_id: filters.teamId || undefined,
      })
    );
    deals.value = normalizePayload(data);
    syncSelectedDeal(deals.value);
  } catch (error) {
    ui.error = error;
  } finally {
    ui.isLoading = false;
  }
};

const syncFilterDraft = () => {
  Object.assign(filterDraft, {
    archived: filters.archived,
    ownerId: filters.ownerId,
    pipelineId: filters.pipelineId,
    q: filters.q,
    teamId: filters.teamId,
  });
};

const openFilterDialog = () => {
  syncFilterDraft();
  filterDialogRef.value?.open();
};

const applyFilters = async () => {
  Object.assign(filters, {
    archived: filterDraft.archived,
    ownerId: filterDraft.ownerId,
    pipelineId: filterDraft.pipelineId,
    q: filterDraft.q,
    teamId: filterDraft.teamId,
  });
  filterDialogRef.value?.close();
  await loadDeals();
};

const handleDealStageChange = async ({ deal, stageId }) => {
  const currentDeal =
    deals.value.find(item => Number(item.id) === Number(deal.id)) || deal;
  const nextStageId = Number(stageId);

  if (!nextStageId || Number(currentDeal.stageId) === nextStageId) {
    return;
  }

  const optimisticDeal = { ...currentDeal, stageId: nextStageId };
  upsertDeal(optimisticDeal);

  if (
    selectedDeal.value &&
    Number(selectedDeal.value.id) === optimisticDeal.id
  ) {
    selectedDeal.value = optimisticDeal;
    form.stageId = nextStageId;
  }

  try {
    const response = await CrmDealsAPI.transitionStage(currentDeal.id, {
      lock_version: currentDeal.lockVersion,
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
    companyId,
    contactIds: contactId ? [contactId] : [],
    originatingConversationDisplayId: queryValue('conversationDisplayId')
      ? `#${queryValue('conversationDisplayId')}`
      : '',
    originatingConversationId: numericQueryValue('originatingConversationId'),
    ownerId: numericQueryValue('ownerId'),
    primaryContactId: contactId,
    teamId: numericQueryValue('teamId'),
    title: buildPrefillDealTitle(),
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
    const company = normalizePayload(response.data);
    companyOptions.value = [
      ...companyOptions.value,
      {
        label: company.name,
        value: company.id,
      },
    ];
  }

  await clearDealPrefillQuery();
};

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

onMounted(async () => {
  if (!canViewDeals.value) return;

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
  resetForm();
  await loadDeals();
  await consumeDealPrefillQuery();
});
</script>

<template>
  <section class="flex flex-1 min-h-0 flex-col overflow-hidden bg-n-surface-1">
    <SchedulingPageHeader
      :title="$t('CRM.DEALS.TITLE')"
      :description="$t('CRM.DEALS.DESCRIPTION')"
    >
      <template #actions>
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
        currentPresentation === 'board' && !ui.isLoading && !ui.error
          ? 'min-h-0 overflow-hidden'
          : 'overflow-y-auto'
      "
    >
      <div
        :class="
          currentPresentation === 'board' && !ui.isLoading && !ui.error
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
          v-else-if="deals.length === 0"
          icon="i-lucide-briefcase-business"
          :title="$t('CRM.DEALS.EMPTY_TITLE')"
          :description="$t('CRM.DEALS.EMPTY_DESCRIPTION')"
          :action-label="canManageDeals ? $t('CRM.DEALS.NEW_DEAL') : ''"
          @action="openCreateDrawer"
        />

        <SchedulingRecordTable
          v-else-if="currentPresentation === 'list'"
          :columns="tableColumns"
          :rows="deals"
        >
          <template #cell-title="{ row }">
            <button
              type="button"
              class="grid gap-1 text-left"
              @click="openEditDrawer(row)"
            >
              <span class="font-medium text-n-slate-12">{{ row.title }}</span>
              <span class="text-xs text-n-slate-11">
                {{
                  pipelineNameById[row.pipelineId] ||
                  $t('CRM.GENERAL.EMPTY_VALUE')
                }}
              </span>
            </button>
          </template>

          <template #cell-stage="{ row }">
            <span class="text-sm text-n-slate-12">
              {{ stageNameById[row.stageId] || $t('CRM.GENERAL.EMPTY_VALUE') }}
            </span>
          </template>

          <template #cell-owner="{ row }">
            <span class="text-sm text-n-slate-12">
              {{ ownerNameById[row.ownerId] || $t('CRM.GENERAL.EMPTY_VALUE') }}
            </span>
          </template>

          <template #cell-amount="{ row }">
            <span class="text-sm text-n-slate-12">
              {{
                row.amountMinor
                  ? `${row.amountMinor}${row.currency ? ` ${row.currency}` : ''}`
                  : $t('CRM.GENERAL.EMPTY_VALUE')
              }}
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

        <CrmDealBoard
          v-else
          class="min-h-0 flex-1"
          :can-manage="canManageDeals"
          :deals="deals"
          :owner-names="ownerNameById"
          :pipeline-names="pipelineNameById"
          :stages="boardStages"
          @change-stage="handleDealStageChange"
          @select-deal="openEditDrawer"
        />
      </div>
    </div>

    <SchedulingDrawer
      v-model="drawerOpen"
      width="xl"
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

        <SchedulingFormFieldGroup
          :framed="false"
          :title="$t('CRM.DEALS.FORM.BASICS')"
        >
          <div class="grid gap-4 md:grid-cols-2">
            <Input
              :label="$t('CRM.DEALS.FORM.TITLE')"
              :model-value="form.title"
              @update:model-value="form.title = $event"
            />
            <SchedulingSelectField
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
              v-model:amount="form.amountMinor"
              v-model:currency="form.currency"
              :currencies="dealCurrencyOptions"
              :currency-aria-label="$t('CRM.DEALS.FORM.CURRENCY')"
              :label="$t('CRM.DEALS.FORM.AMOUNT')"
            />
            <TextArea
              class="md:col-span-2"
              :label="$t('CRM.DEALS.FORM.DESCRIPTION')"
              :model-value="form.description"
              auto-height
              @update:model-value="form.description = $event"
            />
          </div>
        </SchedulingFormFieldGroup>

        <SchedulingFormFieldGroup
          :framed="false"
          :title="$t('CRM.DEALS.FORM.RELATIONSHIPS')"
          :description="$t('CRM.DEALS.FORM.RELATIONSHIPS_DESCRIPTION')"
        >
          <div class="grid gap-4 md:grid-cols-2">
            <div class="grid gap-1 md:col-span-2">
              <span class="mb-0.5 text-sm font-medium text-n-slate-12">
                {{ $t('CRM.DEALS.FORM.CONTACTS') }}
              </span>
              <TagMultiSelectComboBox
                :model-value="form.contactIds"
                :options="contactOptions"
                @update:model-value="form.contactIds = $event"
              />
            </div>
            <SchedulingSelectField
              :label="$t('CRM.DEALS.FORM.PRIMARY_CONTACT')"
              :model-value="form.primaryContactId"
              :options="
                contactOptions.filter(option =>
                  form.contactIds.includes(option.value)
                )
              "
              @open="loadContacts('')"
              @search="loadContacts"
              @update:model-value="form.primaryContactId = $event"
            />
            <SchedulingSelectField
              v-if="companiesEnabled"
              :label="$t('CRM.DEALS.FORM.COMPANY')"
              :model-value="form.companyId"
              :options="companyOptions"
              use-api-results
              @open="loadCompanies('')"
              @search="loadCompanies"
              @update:model-value="form.companyId = $event"
            />
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

      <template v-if="selectedDeal && canManageDeals" #footer>
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
                selectedDeal.archivedAt
                  ? $t('CRM.GENERAL.UNARCHIVE')
                  : $t('CRM.GENERAL.ARCHIVE')
              "
              @click="toggleArchived(selectedDeal)"
            />
            <Button
              size="sm"
              :is-loading="ui.isSaving"
              :disabled="
                !form.title.trim() || !form.pipelineId || !form.stageId
              "
              :label="$t('CRM.GENERAL.SAVE')"
              @click="saveDeal"
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
        <div class="md:col-span-2">
          <Input
            type="search"
            :label="$t('CRM.FILTERS.SEARCH')"
            :model-value="filterDraft.q"
            custom-input-class="ltr:!pl-8 rtl:!pr-8"
            :placeholder="$t('CRM.FILTERS.SEARCH_PLACEHOLDER')"
            @enter="applyFilters"
            @update:model-value="filterDraft.q = $event"
          >
            <template #prefix>
              <Icon
                icon="i-lucide-search"
                class="absolute top-1/2 size-4 -translate-y-1/2 text-n-slate-11 ltr:left-2 rtl:right-2"
              />
            </template>
          </Input>
        </div>

        <SchedulingSelectField
          :label="$t('CRM.DEALS.FORM.PIPELINE')"
          :model-value="filterDraft.pipelineId"
          :options="pipelineOptions"
          :placeholder="$t('CRM.DEALS.FORM.PIPELINE')"
          @update:model-value="filterDraft.pipelineId = $event"
        />

        <SchedulingSelectField
          :label="$t('CRM.DEALS.FORM.OWNER')"
          :model-value="filterDraft.ownerId"
          :options="ownerOptions"
          :placeholder="$t('CRM.DEALS.FORM.OWNER')"
          @update:model-value="filterDraft.ownerId = $event"
        />

        <SchedulingSelectField
          :label="$t('CRM.DEALS.FORM.TEAM')"
          :model-value="filterDraft.teamId"
          :options="teamOptions"
          :placeholder="$t('CRM.DEALS.FORM.TEAM')"
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
