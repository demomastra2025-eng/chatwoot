<script setup>
import { computed, nextTick, reactive, ref, watch } from 'vue';
import { useI18n } from 'vue-i18n';

import CompanyAPI from 'dashboard/api/companies';
import CrmDealsAPI from 'dashboard/api/crm/deals';
import SidebarActionsHeader from 'dashboard/components-next/SidebarActionsHeader.vue';
import Button from 'dashboard/components-next/button/Button.vue';
import Spinner from 'dashboard/components-next/spinner/Spinner.vue';
import Input from 'dashboard/components-next/input/Input.vue';
import TextArea from 'dashboard/components-next/textarea/TextArea.vue';
import SchedulingCurrencyAmountInput from 'dashboard/components-next/Scheduling/SchedulingCurrencyAmountInput.vue';
import SchedulingDateTimeField from 'dashboard/components-next/Scheduling/SchedulingDateTimeField.vue';
import SchedulingSelectField from 'dashboard/components-next/Scheduling/SchedulingSelectField.vue';
import CrmClosingReasonDialog from 'dashboard/components-next/CRM/CrmClosingReasonDialog.vue';
import CrmCustomFieldsSection from 'dashboard/components-next/CRM/CrmCustomFieldsSection.vue';
import CrmDealTasksPanel from 'dashboard/components-next/CRM/CrmDealTasksPanel.vue';
import { DEFAULT_STAGE_COLOR } from 'dashboard/stores/crm/stageColors';
import {
  formatDealAmount,
  majorAmountToMinor,
  resolveDealAmountMajor,
} from 'dashboard/components-next/CRM/dealAmount';
import {
  buildCrmDealLookupParams,
  buildCrmDealOriginLookupParams,
  buildCrmDealSourceContext,
  mergeUniqueCrmDeals,
  sortCrmDealsForContext,
} from 'dashboard/components-next/CRM/crmConversationDealContext';
import { useAlert } from 'dashboard/composables';
import { useMapGetter, useStore } from 'dashboard/composables/store';
import {
  CRM_DEAL_MANAGE_PERMISSIONS,
  CRM_TASK_MANAGE_PERMISSIONS,
} from 'dashboard/constants/permissions';
import { FEATURE_FLAGS } from 'dashboard/featureFlags';
import { hasPermissions } from 'dashboard/helper/permissionsHelper';
import {
  buildDefaultCustomAttributes,
  mergeMissingDefaultCustomAttributes,
} from 'dashboard/stores/crm/customFieldDefaults';
import { useCrmReferencesStore } from 'dashboard/stores/crm/references';
import { resolveDefaultPipelineWithStages } from 'dashboard/components-next/sidebar/crmDefaultPipelineSidebar';
import {
  compactPayload,
  formatCrmErrorMessage,
  normalizePayload,
} from 'dashboard/stores/crm/shared';

const props = defineProps({
  currentChat: {
    type: Object,
    default: () => ({}),
  },
});

const emit = defineEmits(['close']);

const NEW_DEAL_KEY = 'new-deal';
const defaultDealCurrency = 'KZT';
const dealCurrencyOptions = ['KZT', 'USD', 'EUR', 'RUB'];

const { t, locale } = useI18n();
const store = useStore();
const referencesStore = useCrmReferencesStore();

const accountId = useMapGetter('getCurrentAccountId');
const agents = useMapGetter('agents/getAgents');
const currentUser = useMapGetter('getCurrentUser');
const teams = useMapGetter('teams/getTeams');
const isFeatureEnabledonAccount = useMapGetter(
  'accounts/isFeatureEnabledonAccount'
);

const deals = ref([]);
const companyOptions = ref([]);
const closingReasonDialogRef = ref(null);
const openDealKeys = ref([]);
const scrollContainer = ref(null);
const isCreating = ref(false);
const savingDealKey = ref('');
const ui = reactive({
  isInitializing: false,
});
const forms = reactive({});

const currentDealSourceContext = computed(() =>
  buildCrmDealSourceContext(props.currentChat)
);
const metaAdReferral = computed(
  () => currentDealSourceContext.value.metaAdReferral || {}
);
const metaAdReferralValue = (camelKey, snakeKey = camelKey) =>
  metaAdReferral.value?.[camelKey] || metaAdReferral.value?.[snakeKey] || '';
const hasMetaAdReferral = computed(
  () =>
    !!(
      metaAdReferralValue('ctwaClid', 'ctwa_clid') ||
      metaAdReferralValue('adId', 'ad_id') ||
      metaAdReferralValue('sourceId', 'source_id') ||
      metaAdReferral.value?.headline
    )
);
const metaAdReferralProviderLabel = computed(() => {
  const provider = metaAdReferral.value?.provider;
  if (provider === 'whatsapp') {
    return t('CRM.DEALS.META_AD_REFERRAL.PROVIDER_WHATSAPP');
  }
  if (provider === 'instagram') {
    return t('CRM.DEALS.META_AD_REFERRAL.PROVIDER_INSTAGRAM');
  }
  if (provider === 'facebook') {
    return t('CRM.DEALS.META_AD_REFERRAL.PROVIDER_FACEBOOK');
  }
  return t('CRM.DEALS.META_AD_REFERRAL.PROVIDER_META');
});
const metaAdReferralRows = computed(() =>
  [
    {
      label: t('CRM.DEALS.META_AD_REFERRAL.CTWA_CLID'),
      value: metaAdReferralValue('ctwaClid', 'ctwa_clid'),
    },
    {
      label: t('CRM.DEALS.META_AD_REFERRAL.AD_ID'),
      value: metaAdReferralValue('adId', 'ad_id'),
    },
    {
      label: t('CRM.DEALS.META_AD_REFERRAL.SOURCE_ID'),
      value: metaAdReferralValue('sourceId', 'source_id'),
    },
    {
      label: t('CRM.DEALS.META_AD_REFERRAL.SOURCE_URL'),
      value: metaAdReferralValue('sourceUrl', 'source_url'),
    },
  ].filter(row => row.value)
);
const currentUserId = computed(() => {
  const userId = Number(currentUser.value?.id);
  return Number.isFinite(userId) && userId > 0 ? userId : '';
});
const currentAccountPermissions = computed(() => {
  const currentAccount = currentUser.value?.accounts?.find(
    account => Number(account.id) === Number(accountId.value)
  );

  return currentAccount?.permissions || [];
});
const canManageDeals = computed(
  () =>
    isFeatureEnabledonAccount.value(accountId.value, FEATURE_FLAGS.CRM_DEALS) &&
    hasPermissions(CRM_DEAL_MANAGE_PERMISSIONS, currentAccountPermissions.value)
);
const canManageTasks = computed(
  () =>
    isFeatureEnabledonAccount.value(accountId.value, FEATURE_FLAGS.CRM_TASKS) &&
    hasPermissions(CRM_TASK_MANAGE_PERMISSIONS, currentAccountPermissions.value)
);
const companiesEnabled = computed(() =>
  isFeatureEnabledonAccount.value(accountId.value, FEATURE_FLAGS.COMPANIES)
);
const activePipelines = computed(() =>
  referencesStore.pipelines.filter(pipeline => pipeline.active !== false)
);
const defaultPipeline = computed(
  () => resolveDefaultPipelineWithStages(activePipelines.value).pipeline
);
const dealFieldDefinitions = computed(
  () => referencesStore.dealFieldDefinitions
);
const taskFieldDefinitions = computed(
  () => referencesStore.taskFieldDefinitions
);
const taskStatuses = computed(() => referencesStore.taskStatuses);
const dealKey = deal => `deal-${deal.id}`;
const accordionItems = computed(() => {
  const items = deals.value.map(deal => ({
    deal,
    isNew: false,
    key: dealKey(deal),
  }));

  if (isCreating.value || !items.length) {
    return [{ deal: null, isNew: true, key: NEW_DEAL_KEY }, ...items];
  }

  return items;
});
const headerButtons = computed(() =>
  isCreating.value
    ? []
    : [
        {
          icon: 'i-lucide-plus',
          key: 'new_deal',
          tooltip: t('CRM.DEALS.NEW_DEAL'),
        },
      ]
);

const defaultStageForPipeline = pipeline =>
  (pipeline?.stages || []).find(stage => stage.default && stage.active) ||
  (pipeline?.stages || []).find(
    stage => stage.active && stage.outcome === 'open'
  ) ||
  (pipeline?.stages || []).find(stage => stage.active) ||
  pipeline?.stages?.[0];

const stageOptionsForForm = form =>
  (
    referencesStore.pipelines.find(
      pipeline => Number(pipeline.id) === Number(form?.pipelineId)
    )?.stages || []
  ).map(stage => ({
    label: stage.name,
    stageColor: stage.color || DEFAULT_STAGE_COLOR,
    value: stage.id,
  }));

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

const pipelineOptions = computed(() =>
  activePipelines.value.map(pipeline => ({
    icon: 'i-lucide-funnel',
    label: pipeline.name,
    value: pipeline.id,
  }))
);

const teamOptions = computed(() =>
  teams.value.map(team => ({
    label: team.name,
    value: team.id,
  }))
);

const shouldShowTeamFieldForForm = form =>
  teamOptions.value.length > 0 || !!form?.teamId;

const formatReferenceDisplayId = value => {
  if (!value) return '';

  const stringValue = String(value);
  return stringValue.startsWith('#') ? stringValue : `#${stringValue}`;
};

const normalizedTextValues = values => [
  ...new Set(
    (Array.isArray(values) ? values : [values])
      .map(value => String(value || '').trim())
      .filter(Boolean)
  ),
];

const isTerminalStage = stage => ['won', 'lost'].includes(stage?.outcome);
const closingReasonOptionsForStage = stage =>
  normalizedTextValues(stage?.closingReasonOptions);
const transitionReasonOptionsForStage = stage =>
  normalizedTextValues(stage?.transitionReasonOptions);
const shouldPromptForClosingReasons = stage =>
  isTerminalStage(stage) && closingReasonOptionsForStage(stage).length > 0;
const shouldPromptForTransitionReason = stage =>
  !isTerminalStage(stage) && transitionReasonOptionsForStage(stage).length > 0;
const isStageReasonCancelled = value =>
  value === closingReasonDialogRef.value?.CANCELLED;

const collectClosingReasonsForStage = async ({
  form,
  targetStage,
  deal = null,
}) => {
  if (!targetStage) return [];
  if (!shouldPromptForClosingReasons(targetStage)) return [];

  return (
    closingReasonDialogRef.value?.open({
      currentReasons: normalizedTextValues(
        deal?.closingReasons || form?.closingReasons
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

const buildPrefillDealTitle = () => {
  const contact = currentDealSourceContext.value.contact;
  if (contact?.name) {
    return t('CRM.DEALS.PREFILL.CONVERSATION_WITH_CONTACT', {
      contactName: contact.name,
    });
  }

  if (currentDealSourceContext.value.originatingCommunicationThreadId) {
    return t('CRM.DEALS.PREFILL.COMMUNICATION_THREAD_GENERIC', {
      threadId: currentDealSourceContext.value.originatingCommunicationThreadId,
    });
  }

  if (currentDealSourceContext.value.originatingConversationId) {
    return t('CRM.DEALS.PREFILL.CONVERSATION_GENERIC', {
      conversationId: currentDealSourceContext.value.originatingConversationId,
    });
  }

  return '';
};

const buildNewDealForm = () => {
  const resolvedDefaultPipeline = defaultPipeline.value;
  const defaultStage = defaultStageForPipeline(resolvedDefaultPipeline);
  const contactId = currentDealSourceContext.value.contactId || '';

  return {
    amount: 0,
    companyId: '',
    contactIds: contactId ? [Number(contactId)] : [],
    closingReasons: [],
    currency: defaultDealCurrency,
    customAttributes: buildDefaultCustomAttributes(dealFieldDefinitions.value),
    description: '',
    expectedCloseOn: '',
    externalRef: '',
    originatingCommunicationThreadDisplayId:
      currentDealSourceContext.value.originatingCommunicationThreadDisplayId,
    originatingCommunicationThreadId:
      currentDealSourceContext.value.originatingCommunicationThreadId,
    originatingConversationDisplayId:
      currentDealSourceContext.value.originatingConversationDisplayId,
    originatingConversationId:
      currentDealSourceContext.value.originatingConversationId,
    ownerId: props.currentChat?.meta?.assignee?.id || currentUserId.value,
    pipelineId: resolvedDefaultPipeline?.id || '',
    primaryContactId: contactId || '',
    stageId: defaultStage?.id || '',
    teamId: props.currentChat?.meta?.team?.id || '',
    title: buildPrefillDealTitle(),
    winProbability: '',
  };
};

const formFromDeal = deal => {
  const contactIds = [
    deal.primaryContactId,
    ...(deal.dealContacts || []).map(contact => contact.contactId),
  ]
    .map(Number)
    .filter(contactId => Number.isFinite(contactId) && contactId > 0);

  return {
    amount: resolveDealAmountMajor(deal) ?? 0,
    companyId: deal.companyId ?? '',
    contactIds: [...new Set(contactIds)],
    closingReasons: normalizedTextValues(deal.closingReasons),
    currency: deal.currency || defaultDealCurrency,
    customAttributes: mergeMissingDefaultCustomAttributes(
      { ...(deal.customAttributes || {}) },
      dealFieldDefinitions.value
    ),
    description: deal.description || '',
    expectedCloseOn: deal.expectedCloseOn
      ? deal.expectedCloseOn.slice(0, 10)
      : '',
    externalRef: deal.externalRef || '',
    originatingCommunicationThreadDisplayId: formatReferenceDisplayId(
      deal.originatingCommunicationThreadDisplayId ??
        deal.originatingCommunicationThreadId
    ),
    originatingCommunicationThreadId:
      deal.originatingCommunicationThreadDisplayId ??
      deal.originatingCommunicationThreadId ??
      '',
    originatingConversationDisplayId: formatReferenceDisplayId(
      deal.originatingConversationDisplayId ?? deal.originatingConversationId
    ),
    originatingConversationId: deal.originatingConversationId ?? '',
    ownerId: deal.ownerId ?? '',
    pipelineId: deal.pipelineId,
    primaryContactId: deal.primaryContactId ?? '',
    stageId: deal.stageId,
    teamId: deal.teamId ?? '',
    title: deal.title || '',
    winProbability: deal.winProbability ?? '',
  };
};

const resetForms = () => {
  Object.keys(forms).forEach(key => delete forms[key]);
};

const setNewDealForm = () => {
  forms[NEW_DEAL_KEY] = buildNewDealForm();
};

const setDealForms = () => {
  resetForms();
  deals.value.forEach(deal => {
    forms[dealKey(deal)] = formFromDeal(deal);
  });

  if (isCreating.value || !deals.value.length) {
    setNewDealForm();
  }
};

const loadCompanies = async () => {
  if (!companiesEnabled.value) {
    companyOptions.value = [];
    return;
  }

  const response = await CompanyAPI.get();
  companyOptions.value = normalizePayload(response.data).map(company => ({
    label: company.name,
    value: company.id,
  }));
};

const fetchDealsByParams = async params => {
  if (!params) return [];

  const response = await CrmDealsAPI.get(params);
  return normalizePayload(response.data);
};

const loadDeals = async () => {
  const context = currentDealSourceContext.value;
  const lookupParams = buildCrmDealLookupParams(context);
  const originLookupParams = buildCrmDealOriginLookupParams(context);
  const shouldFetchOrigin =
    originLookupParams &&
    JSON.stringify(originLookupParams) !== JSON.stringify(lookupParams);

  const [lookupDeals, originDeals] = await Promise.all([
    fetchDealsByParams(lookupParams),
    shouldFetchOrigin ? fetchDealsByParams(originLookupParams) : [],
  ]);

  deals.value = sortCrmDealsForContext(
    mergeUniqueCrmDeals(lookupDeals, originDeals),
    context
  );
};

const initializeSidebar = async () => {
  if (!props.currentChat?.id || !canManageDeals.value) return;

  ui.isInitializing = true;
  isCreating.value = false;
  openDealKeys.value = [];

  try {
    if (!agents.value.length) await store.dispatch('agents/get');
    if (!teams.value.length) await store.dispatch('teams/get');

    await Promise.all([
      referencesStore.loadPipelines(),
      referencesStore.loadTaskStatuses(),
      referencesStore.loadFieldDefinitions('deal'),
      referencesStore.loadFieldDefinitions('task'),
      loadCompanies(),
    ]);
    await loadDeals();

    isCreating.value = deals.value.length === 0;
    setDealForms();
    openDealKeys.value = [
      isCreating.value ? NEW_DEAL_KEY : dealKey(deals.value[0]),
    ];
  } catch (error) {
    useAlert(formatCrmErrorMessage(error, t));
  } finally {
    ui.isInitializing = false;
  }
};

const isDealOpen = key => openDealKeys.value.includes(key);

const toggleDeal = key => {
  openDealKeys.value = isDealOpen(key)
    ? openDealKeys.value.filter(openKey => openKey !== key)
    : [...openDealKeys.value, key];
};

const scrollDealsToTop = async () => {
  await nextTick();

  const scheduleFrame =
    typeof window !== 'undefined' && window.requestAnimationFrame
      ? window.requestAnimationFrame
      : callback => callback();
  scheduleFrame(() => {
    scrollContainer.value?.scrollTo({ top: 0, behavior: 'smooth' });
  });
};

const startCreateDeal = () => {
  isCreating.value = true;
  setNewDealForm();
  if (!isDealOpen(NEW_DEAL_KEY)) {
    openDealKeys.value = [NEW_DEAL_KEY, ...openDealKeys.value];
  }
  scrollDealsToTop();
};

const cancelCreateDeal = () => {
  if (!deals.value.length) return;

  isCreating.value = false;
  delete forms[NEW_DEAL_KEY];
  openDealKeys.value = openDealKeys.value.filter(key => key !== NEW_DEAL_KEY);
};

const handleHeaderAction = key => {
  if (key === 'new_deal') {
    startCreateDeal();
  }
};

const pipelineForForm = form =>
  referencesStore.pipelines.find(
    pipeline => Number(pipeline.id) === Number(form?.pipelineId)
  );

const stageForForm = form =>
  (pipelineForForm(form)?.stages || []).find(
    stage => Number(stage.id) === Number(form?.stageId)
  );

const accordionTitle = item => {
  if (item.isNew) return t('CRM.DEALS.NEW_DEAL');

  return item.deal?.title || t('CRM.DEALS.TABLE.TITLE');
};

const accordionMeta = item => {
  const form = forms[item.key];
  if (!form) return '';

  return [
    pipelineForForm(form)?.name,
    stageForForm(form)?.name,
    formatDealAmount({
      amount: form.amount,
      currency: form.currency,
      locale: locale.value,
    }),
  ]
    .filter(Boolean)
    .join(' · ');
};

const stageColorForItem = item => {
  const form = forms[item.key];
  return stageForForm(form)?.color || DEFAULT_STAGE_COLOR;
};

const syncStageAfterPipelineChange = form => {
  const pipeline = pipelineForForm(form);
  const defaultStage = defaultStageForPipeline(pipeline);

  if (
    !pipeline?.stages?.some(stage => Number(stage.id) === Number(form.stageId))
  ) {
    form.stageId = defaultStage?.id || '';
  }
};

const buildPayload = form =>
  compactPayload({
    amount_minor: majorAmountToMinor(form.amount),
    company_id: form.companyId ? Number(form.companyId) : undefined,
    contact_ids: form.contactIds.map(Number),
    closing_reasons: normalizedTextValues(form.closingReasons),
    currency: form.currency || undefined,
    custom_attributes: form.customAttributes,
    description: form.description || undefined,
    expected_close_on: form.expectedCloseOn || undefined,
    external_ref: form.externalRef || undefined,
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

const upsertDeal = deal => {
  const index = deals.value.findIndex(
    item => Number(item.id) === Number(deal.id)
  );
  const nextDeals = [...deals.value];

  if (index === -1) {
    nextDeals.unshift(deal);
  } else {
    nextDeals.splice(index, 1, deal);
  }

  deals.value = sortCrmDealsForContext(
    nextDeals,
    currentDealSourceContext.value
  );
};

const refreshCrmSidebarCounters = () => {
  Promise.allSettled([
    referencesStore.loadPipelines(),
    store.dispatch('fetchSidebarUnreadCounts'),
  ]);
};

const saveDeal = async item => {
  const form = forms[item.key];
  if (!form || !form.title.trim() || !form.pipelineId || !form.stageId) return;

  const targetStage = stageForForm(form);
  const stageChanging =
    !item.deal?.id || Number(form.stageId) !== Number(item.deal.stageId);

  let transitionReason = '';

  if (stageChanging) {
    const closingReasons = await collectClosingReasonsForStage({
      deal: item.deal,
      form,
      targetStage,
    });

    if (isStageReasonCancelled(closingReasons)) return;

    transitionReason = item.deal?.id
      ? await collectTransitionReasonForStage({ targetStage })
      : '';

    if (isStageReasonCancelled(transitionReason)) return;

    form.closingReasons = closingReasons;
  }

  savingDealKey.value = item.key;

  try {
    const payload = buildPayload(form);
    let savedDeal;

    if (item.deal?.id) {
      const currentStageId = item.deal.stageId;
      const {
        closing_reasons: _closingReasons,
        stage_id: _stageId,
        ...updatePayload
      } = {
        ...payload,
        lock_version: item.deal.lockVersion,
      };
      const response = await CrmDealsAPI.update(item.deal.id, updatePayload);
      savedDeal = normalizePayload(response.data);

      if (Number(form.stageId) !== Number(currentStageId) && form.stageId) {
        const transitionResponse = await CrmDealsAPI.transitionStage(
          savedDeal.id,
          {
            closing_reasons: form.closingReasons,
            lock_version: savedDeal.lockVersion,
            stage_id: Number(form.stageId),
            transition_reason: transitionReason || undefined,
          }
        );
        savedDeal = normalizePayload(transitionResponse.data);
      }
    } else {
      const response = await CrmDealsAPI.create(payload);
      savedDeal = normalizePayload(response.data);
      isCreating.value = false;
      delete forms[NEW_DEAL_KEY];
    }

    upsertDeal(savedDeal);
    refreshCrmSidebarCounters();
    forms[dealKey(savedDeal)] = formFromDeal(savedDeal);
    openDealKeys.value = [dealKey(savedDeal)];
    useAlert(
      item.deal?.id
        ? t('CRM.DEALS.SUCCESS_UPDATED')
        : t('CRM.DEALS.SUCCESS_CREATED')
    );
  } catch (error) {
    useAlert(error.message || formatCrmErrorMessage(error, t));
  } finally {
    savingDealKey.value = '';
  }
};

watch(() => [props.currentChat?.id, canManageDeals.value], initializeSidebar, {
  immediate: true,
});

watch(dealFieldDefinitions, definitions => {
  if (!definitions.length) return;

  Object.keys(forms).forEach(key => {
    forms[key].customAttributes = mergeMissingDefaultCustomAttributes(
      forms[key].customAttributes,
      definitions
    );
  });
});
</script>

<template>
  <div class="flex h-full min-w-0 flex-1 flex-col">
    <SidebarActionsHeader
      :title="$t('CRM.DEALS.SIDEBAR_TITLE')"
      :buttons="headerButtons"
      @click="handleHeaderAction"
      @close="emit('close')"
    />

    <div
      ref="scrollContainer"
      class="flex min-h-0 flex-1 flex-col overflow-y-auto pb-5"
    >
      <div v-if="ui.isInitializing" class="flex justify-center py-12">
        <Spinner class="!h-8 !w-8" />
      </div>

      <div v-else class="border-t border-n-weak">
        <div
          v-if="hasMetaAdReferral"
          class="m-3 rounded-lg border border-blue-500/30 bg-blue-50 p-3 text-xs text-blue-950 dark:bg-blue-950/30 dark:text-blue-100"
          data-test-id="crm-meta-ad-referral"
        >
          <div class="mb-1 flex items-center gap-2 font-medium">
            <span class="i-lucide-megaphone size-4" />
            <span>{{ $t('CRM.DEALS.META_AD_REFERRAL.TITLE') }}</span>
            <span
              class="rounded-full bg-blue-100 px-2 py-0.5 text-blue-700 dark:bg-blue-900 dark:text-blue-100"
            >
              {{ metaAdReferralProviderLabel }}
            </span>
          </div>
          <div v-if="metaAdReferral.headline" class="font-medium">
            {{ metaAdReferral.headline }}
          </div>
          <div
            v-if="metaAdReferral.body"
            class="mt-0.5 text-blue-800 dark:text-blue-200"
          >
            {{ metaAdReferral.body }}
          </div>
          <dl v-if="metaAdReferralRows.length" class="mt-2 grid gap-1">
            <div
              v-for="row in metaAdReferralRows"
              :key="row.label"
              class="grid grid-cols-[5.75rem_minmax(0,1fr)] gap-2"
            >
              <dt class="text-blue-700 dark:text-blue-200">{{ row.label }}</dt>
              <dd class="truncate font-mono text-[11px]" :title="row.value">
                {{ row.value }}
              </dd>
            </div>
          </dl>
        </div>

        <section
          v-for="item in accordionItems"
          :key="item.key"
          class="border-b border-n-weak bg-n-solid-1"
        >
          <button
            type="button"
            class="flex w-full p-0 text-left hover:bg-n-alpha-1 rtl:text-right"
            @click="toggleDeal(item.key)"
          >
            <span
              class="my-0.5 w-1 shrink-0 self-stretch rounded-full"
              :style="{ backgroundColor: stageColorForItem(item) }"
            />
            <span
              class="flex min-w-0 flex-1 items-start justify-between gap-3 px-3 py-2.5"
            >
              <span class="min-w-0">
                <span
                  class="block truncate text-sm font-medium text-n-slate-12"
                >
                  {{ accordionTitle(item) }}
                </span>
                <span class="block truncate text-xs leading-5 text-n-slate-11">
                  {{ accordionMeta(item) }}
                </span>
              </span>
              <span
                class="i-lucide-chevron-down mt-0.5 size-4 shrink-0 text-n-slate-10 transition-transform"
                :class="{ 'rotate-180': isDealOpen(item.key) }"
              />
            </span>
          </button>

          <div
            v-show="isDealOpen(item.key)"
            class="border-t border-n-weak px-4 py-3"
          >
            <div v-if="forms[item.key]" class="grid gap-3">
              <div class="crm-deal-drawer-form">
                <div
                  class="crm-deal-drawer-section crm-deal-drawer-section--top"
                >
                  <div class="crm-deal-drawer-row">
                    <label
                      class="crm-deal-drawer-label"
                      :for="`crm-conversation-deal-title-${item.key}`"
                    >
                      {{ $t('CRM.DEALS.FORM.TITLE') }}
                    </label>
                    <Input
                      :id="`crm-conversation-deal-title-${item.key}`"
                      class="crm-deal-drawer-control"
                      custom-input-class="!rounded-md !bg-n-alpha-black2"
                      :aria-label="$t('CRM.DEALS.FORM.TITLE')"
                      :model-value="forms[item.key].title"
                      size="sm"
                      @update:model-value="forms[item.key].title = $event"
                    />
                  </div>

                  <div class="crm-deal-drawer-status-grid">
                    <div class="crm-deal-drawer-row">
                      <label
                        class="crm-deal-drawer-label"
                        :for="`crm-conversation-deal-pipeline-${item.key}`"
                      >
                        {{ $t('CRM.DEALS.FORM.PIPELINE') }}
                      </label>
                      <SchedulingSelectField
                        :id="`crm-conversation-deal-pipeline-${item.key}`"
                        class="crm-deal-drawer-control crm-deal-drawer-select-control"
                        :aria-label="$t('CRM.DEALS.FORM.PIPELINE')"
                        :model-value="forms[item.key].pipelineId"
                        :options="pipelineOptions"
                        :placeholder="$t('CRM.DEALS.FORM.PIPELINE')"
                        dropdown-placement="auto"
                        @update:model-value="
                          value => {
                            forms[item.key].pipelineId = value;
                            syncStageAfterPipelineChange(forms[item.key]);
                          }
                        "
                      />
                    </div>

                    <div class="crm-deal-drawer-row">
                      <label
                        class="crm-deal-drawer-label"
                        :for="`crm-conversation-deal-stage-${item.key}`"
                      >
                        {{ $t('CRM.DEALS.FORM.STAGE') }}
                      </label>
                      <SchedulingSelectField
                        :id="`crm-conversation-deal-stage-${item.key}`"
                        class="crm-deal-drawer-control crm-deal-drawer-select-control"
                        :aria-label="$t('CRM.DEALS.FORM.STAGE')"
                        :model-value="forms[item.key].stageId"
                        :options="stageOptionsForForm(forms[item.key])"
                        :placeholder="$t('CRM.DEALS.FORM.STAGE')"
                        dropdown-placement="auto"
                        @update:model-value="forms[item.key].stageId = $event"
                      />
                    </div>

                    <div class="crm-deal-drawer-row">
                      <label
                        class="crm-deal-drawer-label"
                        :for="`crm-conversation-deal-owner-${item.key}`"
                      >
                        {{ $t('CRM.DEALS.FORM.OWNER') }}
                      </label>
                      <SchedulingSelectField
                        :id="`crm-conversation-deal-owner-${item.key}`"
                        class="crm-deal-drawer-control crm-deal-drawer-select-control"
                        :aria-label="$t('CRM.DEALS.FORM.OWNER')"
                        :model-value="forms[item.key].ownerId"
                        :options="ownerOptions"
                        :placeholder="$t('CRM.DEALS.FORM.OWNER')"
                        dropdown-placement="auto"
                        @update:model-value="forms[item.key].ownerId = $event"
                      />
                    </div>
                  </div>

                  <div
                    v-if="shouldShowTeamFieldForForm(forms[item.key])"
                    class="crm-deal-drawer-row"
                  >
                    <label
                      class="crm-deal-drawer-label"
                      :for="`crm-conversation-deal-team-${item.key}`"
                    >
                      {{ $t('CRM.DEALS.FORM.TEAM') }}
                    </label>
                    <SchedulingSelectField
                      :id="`crm-conversation-deal-team-${item.key}`"
                      class="crm-deal-drawer-control crm-deal-drawer-select-control"
                      :aria-label="$t('CRM.DEALS.FORM.TEAM')"
                      :model-value="forms[item.key].teamId"
                      :options="teamOptions"
                      :placeholder="$t('CRM.DEALS.FORM.TEAM')"
                      dropdown-placement="auto"
                      @update:model-value="forms[item.key].teamId = $event"
                    />
                  </div>

                  <div class="crm-deal-drawer-row">
                    <span class="crm-deal-drawer-label">
                      {{ $t('CRM.DEALS.FORM.EXPECTED_CLOSE_ON') }}
                    </span>
                    <SchedulingDateTimeField
                      class="crm-deal-drawer-control"
                      :aria-label="$t('CRM.DEALS.FORM.EXPECTED_CLOSE_ON')"
                      :model-value="forms[item.key].expectedCloseOn"
                      :placeholder="$t('CRM.DEALS.FORM.EXPECTED_CLOSE_ON')"
                      type="date"
                      @update:model-value="
                        forms[item.key].expectedCloseOn = $event
                      "
                    />
                  </div>

                  <div class="crm-deal-drawer-row">
                    <label
                      class="crm-deal-drawer-label"
                      :for="`crm-conversation-deal-amount-${item.key}`"
                    >
                      {{ $t('CRM.DEALS.FORM.AMOUNT') }}
                    </label>
                    <div
                      class="crm-deal-drawer-control crm-deal-drawer-amount-control"
                    >
                      <SchedulingCurrencyAmountInput
                        :id="`crm-conversation-deal-amount-${item.key}`"
                        v-model:amount="forms[item.key].amount"
                        v-model:currency="forms[item.key].currency"
                        :aria-label="$t('CRM.DEALS.FORM.AMOUNT')"
                        :currencies="dealCurrencyOptions"
                        :currency-aria-label="$t('CRM.DEALS.FORM.CURRENCY')"
                        size="sm"
                        step="1"
                      />
                    </div>
                  </div>

                  <div v-if="companiesEnabled" class="crm-deal-drawer-row">
                    <label
                      class="crm-deal-drawer-label"
                      :for="`crm-conversation-deal-company-${item.key}`"
                    >
                      {{ $t('CRM.DEALS.FORM.COMPANY') }}
                    </label>
                    <SchedulingSelectField
                      :id="`crm-conversation-deal-company-${item.key}`"
                      class="crm-deal-drawer-control crm-deal-drawer-select-control"
                      :aria-label="$t('CRM.DEALS.FORM.COMPANY')"
                      :model-value="forms[item.key].companyId"
                      :options="companyOptions"
                      :placeholder="$t('CRM.DEALS.FORM.COMPANY')"
                      dropdown-placement="auto"
                      @update:model-value="forms[item.key].companyId = $event"
                    />
                  </div>
                </div>

                <CrmCustomFieldsSection
                  :definitions="dealFieldDefinitions"
                  :framed="false"
                  layout="rows"
                  :model-value="forms[item.key].customAttributes"
                  @update:model-value="
                    forms[item.key].customAttributes = $event
                  "
                />

                <div class="crm-deal-drawer-section">
                  <div class="crm-deal-drawer-row crm-deal-drawer-row--start">
                    <label
                      class="crm-deal-drawer-label"
                      :for="`crm-conversation-deal-description-${item.key}`"
                    >
                      {{ $t('CRM.DEALS.FORM.DESCRIPTION') }}
                    </label>
                    <TextArea
                      :id="`crm-conversation-deal-description-${item.key}`"
                      class="crm-deal-drawer-control"
                      :aria-label="$t('CRM.DEALS.FORM.DESCRIPTION')"
                      :model-value="forms[item.key].description"
                      auto-height
                      custom-text-area-wrapper-class="!rounded-md !border-n-weak !bg-n-alpha-black2 !px-2 !py-1 hover:!border-n-slate-6"
                      min-height="3rem"
                      @update:model-value="forms[item.key].description = $event"
                    />
                  </div>
                </div>
              </div>

              <CrmDealTasksPanel
                v-if="item.deal?.id"
                :assignees="ownerOptions"
                :can-manage-tasks="canManageTasks"
                create-action-icon-only
                :deal="item.deal"
                :statuses="taskStatuses"
                :task-field-definitions="taskFieldDefinitions"
                :team-options="teamOptions"
              />

              <div class="flex items-center justify-end gap-2">
                <Button
                  v-if="item.isNew && deals.length"
                  size="sm"
                  slate
                  faded
                  :label="$t('CRM.GENERAL.CANCEL')"
                  @click="cancelCreateDeal"
                />
                <Button
                  size="sm"
                  color="blue"
                  :is-loading="savingDealKey === item.key"
                  :disabled="
                    !forms[item.key].title.trim() ||
                    !forms[item.key].pipelineId ||
                    !forms[item.key].stageId
                  "
                  :label="$t('CRM.GENERAL.SAVE')"
                  @click="saveDeal(item)"
                />
              </div>
            </div>
          </div>
        </section>
      </div>
    </div>
    <CrmClosingReasonDialog ref="closingReasonDialogRef" />
  </div>
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
  @apply grid gap-2;
}

.crm-deal-drawer-status-grid :deep(button) {
  @apply min-w-0;
}

.crm-deal-drawer-row {
  display: grid;
  gap: 0.375rem;
  min-width: 0;
}

.crm-deal-drawer-label {
  @apply mb-0 min-w-0 text-[13px] font-medium leading-4 text-n-slate-12;
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
.crm-deal-drawer-form :deep(.crm-deal-drawer-select-control button) {
  @apply justify-start py-1 !important;
}

.crm-deal-drawer-form :deep(.crm-deal-drawer-control input:hover),
.crm-deal-drawer-form :deep(.crm-deal-drawer-control select:hover),
.crm-deal-drawer-form
  :deep(.crm-deal-drawer-control .reka-date-time-picker__trigger:hover),
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
.crm-deal-drawer-form :deep(.crm-deal-drawer-select-control button:focus),
.crm-deal-drawer-form
  :deep(.crm-deal-drawer-select-control button[data-state='open']) {
  @apply border-n-weak bg-n-alpha-black2 outline-n-brand !important;
}

.crm-deal-drawer-form :deep(.crm-deal-drawer-control textarea) {
  @apply text-sm font-normal text-n-slate-12 !important;
}

@media (min-width: 768px) {
  .crm-deal-drawer-row {
    align-items: center;
    grid-template-columns: minmax(6.5rem, 1fr) minmax(8rem, 14rem);
  }

  .crm-deal-drawer-row--start {
    align-items: start;
  }

  .crm-deal-drawer-label {
    @apply text-left;
  }

  .crm-deal-drawer-row--start > .crm-deal-drawer-label {
    padding-top: 0.5rem;
  }
}
</style>
