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
import SchedulingFormFieldGroup from 'dashboard/components-next/Scheduling/SchedulingFormFieldGroup.vue';
import SchedulingSelectField from 'dashboard/components-next/Scheduling/SchedulingSelectField.vue';
import CrmCustomFieldsSection from 'dashboard/components-next/CRM/CrmCustomFieldsSection.vue';
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
import { CRM_DEAL_MANAGE_PERMISSIONS } from 'dashboard/constants/permissions';
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
    value: stage.id,
  }));

const ownerOptions = computed(() =>
  agents.value.map(agent => ({
    label: agent.name || agent.email,
    thumbnail: { name: agent.name || agent.email },
    value: agent.id,
  }))
);

const teamOptions = computed(() =>
  teams.value.map(team => ({
    label: team.name,
    value: team.id,
  }))
);

const formatReferenceDisplayId = value => {
  if (!value) return '';

  const stringValue = String(value);
  return stringValue.startsWith('#') ? stringValue : `#${stringValue}`;
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
      referencesStore.loadFieldDefinitions('deal'),
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

  savingDealKey.value = item.key;

  try {
    const payload = buildPayload(form);
    let savedDeal;

    if (item.deal?.id) {
      const currentStageId = item.deal.stageId;
      const { stage_id: _stageId, ...updatePayload } = {
        ...payload,
        lock_version: item.deal.lockVersion,
      };
      const response = await CrmDealsAPI.update(item.deal.id, updatePayload);
      savedDeal = normalizePayload(response.data);

      if (Number(form.stageId) !== Number(currentStageId) && form.stageId) {
        const transitionResponse = await CrmDealsAPI.transitionStage(
          savedDeal.id,
          {
            lock_version: savedDeal.lockVersion,
            stage_id: Number(form.stageId),
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
              class="w-1 shrink-0 self-stretch"
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

          <div v-show="isDealOpen(item.key)" class="border-t border-n-weak p-3">
            <div v-if="forms[item.key]" class="grid gap-3">
              <SchedulingFormFieldGroup :framed="false">
                <div class="grid gap-2">
                  <Input
                    :label="$t('CRM.DEALS.FORM.TITLE')"
                    :model-value="forms[item.key].title"
                    @update:model-value="forms[item.key].title = $event"
                  />
                  <div class="grid grid-cols-2 gap-2">
                    <SchedulingSelectField
                      :label="$t('CRM.DEALS.FORM.PIPELINE')"
                      :model-value="forms[item.key].pipelineId"
                      :options="
                        activePipelines.map(pipeline => ({
                          label: pipeline.name,
                          value: pipeline.id,
                        }))
                      "
                      dropdown-placement="top"
                      @update:model-value="
                        value => {
                          forms[item.key].pipelineId = value;
                          syncStageAfterPipelineChange(forms[item.key]);
                        }
                      "
                    />
                    <SchedulingSelectField
                      :label="$t('CRM.DEALS.FORM.STAGE')"
                      :model-value="forms[item.key].stageId"
                      :options="stageOptionsForForm(forms[item.key])"
                      dropdown-placement="top"
                      @update:model-value="forms[item.key].stageId = $event"
                    />
                    <SchedulingSelectField
                      :label="$t('CRM.DEALS.FORM.OWNER')"
                      :model-value="forms[item.key].ownerId"
                      :options="ownerOptions"
                      dropdown-placement="top"
                      @update:model-value="forms[item.key].ownerId = $event"
                    />
                    <SchedulingSelectField
                      :label="$t('CRM.DEALS.FORM.TEAM')"
                      :model-value="forms[item.key].teamId"
                      :options="teamOptions"
                      dropdown-placement="top"
                      @update:model-value="forms[item.key].teamId = $event"
                    />
                    <SchedulingDateTimeField
                      :label="$t('CRM.DEALS.FORM.EXPECTED_CLOSE_ON')"
                      :model-value="forms[item.key].expectedCloseOn"
                      type="date"
                      @update:model-value="
                        forms[item.key].expectedCloseOn = $event
                      "
                    />
                  </div>
                  <SchedulingCurrencyAmountInput
                    v-model:amount="forms[item.key].amount"
                    v-model:currency="forms[item.key].currency"
                    :currencies="dealCurrencyOptions"
                    :currency-aria-label="$t('CRM.DEALS.FORM.CURRENCY')"
                    step="1"
                    :label="$t('CRM.DEALS.FORM.AMOUNT')"
                  />
                  <SchedulingSelectField
                    v-if="companiesEnabled"
                    :label="$t('CRM.DEALS.FORM.COMPANY')"
                    :model-value="forms[item.key].companyId"
                    :options="companyOptions"
                    dropdown-placement="top"
                    @update:model-value="forms[item.key].companyId = $event"
                  />
                </div>
              </SchedulingFormFieldGroup>

              <CrmCustomFieldsSection
                :definitions="dealFieldDefinitions"
                :framed="false"
                :model-value="forms[item.key].customAttributes"
                @update:model-value="forms[item.key].customAttributes = $event"
              />

              <SchedulingFormFieldGroup :framed="false">
                <TextArea
                  :label="$t('CRM.DEALS.FORM.DESCRIPTION')"
                  :model-value="forms[item.key].description"
                  auto-height
                  @update:model-value="forms[item.key].description = $event"
                />
              </SchedulingFormFieldGroup>

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
  </div>
</template>
