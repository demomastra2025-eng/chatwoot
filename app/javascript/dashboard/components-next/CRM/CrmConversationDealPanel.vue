<script setup>
import { computed, reactive, ref, watch } from 'vue';
import { useI18n } from 'vue-i18n';
import { onBeforeRouteLeave, useRoute } from 'vue-router';

import CompanyAPI from 'dashboard/api/companies';
import ContactAPI from 'dashboard/api/contacts';
import CrmDealsAPI from 'dashboard/api/crm/deals';
import { useAlert } from 'dashboard/composables';
import { useMapGetter, useStore } from 'dashboard/composables/store';
import { FEATURE_FLAGS } from 'dashboard/featureFlags';
import { CRM_DEAL_MANAGE_PERMISSIONS } from 'dashboard/constants/permissions';
import { hasPermissions } from 'dashboard/helper/permissionsHelper';
import Button from 'dashboard/components-next/button/Button.vue';
import Spinner from 'dashboard/components-next/spinner/Spinner.vue';
import TextArea from 'dashboard/components-next/textarea/TextArea.vue';
import SchedulingCurrencyAmountInput from 'dashboard/components-next/Scheduling/SchedulingCurrencyAmountInput.vue';
import SchedulingDateTimeField from 'dashboard/components-next/Scheduling/SchedulingDateTimeField.vue';
import SchedulingFormFieldGroup from 'dashboard/components-next/Scheduling/SchedulingFormFieldGroup.vue';
import SchedulingSelectField from 'dashboard/components-next/Scheduling/SchedulingSelectField.vue';
import SchedulingSidePanel from 'dashboard/components-next/Scheduling/SchedulingSidePanel.vue';
import EntityTouchesCard from 'dashboard/components-next/Outbound/EntityTouchesCard.vue';
import TagMultiSelectComboBox from 'dashboard/components-next/combobox/TagMultiSelectComboBox.vue';
import Input from 'dashboard/components-next/input/Input.vue';
import CreateCompanyDialog from 'dashboard/components-next/Companies/CompanyForm/CreateCompanyDialog.vue';
import CreateNewContactDialog from 'dashboard/components-next/Contacts/ContactsForm/CreateNewContactDialog.vue';
import CrmCustomFieldsSection from 'dashboard/components-next/CRM/CrmCustomFieldsSection.vue';
import {
  majorAmountToMinor,
  resolveDealAmountMajor,
} from 'dashboard/components-next/CRM/dealAmount';
import { useCrmReferencesStore } from 'dashboard/stores/crm/references';
import {
  buildDefaultCustomAttributes,
  mergeMissingDefaultCustomAttributes,
} from 'dashboard/stores/crm/customFieldDefaults';
import {
  compactPayload,
  formatCrmErrorMessage,
  normalizePayload,
} from 'dashboard/stores/crm/shared';
import {
  DuplicateContactException,
  ExceptionWithMessage,
} from 'shared/helpers/CustomErrors';
import {
  isAConversationRoute,
  isAInboxViewRoute,
} from 'dashboard/helper/routeHelpers';

const props = defineProps({
  currentChat: {
    type: Object,
    default: () => ({}),
  },
  modelValue: {
    type: Boolean,
    default: false,
  },
});

const emit = defineEmits(['close', 'saved', 'update:modelValue']);

const { t } = useI18n();
const route = useRoute();
const store = useStore();
const referencesStore = useCrmReferencesStore();

const createCompanyDialogRef = ref(null);
const createNewContactDialogRef = ref(null);
const contactOptions = ref([]);
const companyOptions = ref([]);
const pendingCreateCustomFieldDefaultsHydration = ref(false);
const selectedDeal = ref(null);

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
  isInitializing: false,
  isSaving: false,
});

const accountId = useMapGetter('getCurrentAccountId');
const agents = useMapGetter('agents/getAgents');
const currentUser = useMapGetter('getCurrentUser');
const teams = useMapGetter('teams/getTeams');
const isFeatureEnabledonAccount = useMapGetter(
  'accounts/isFeatureEnabledonAccount'
);

const currentUserId = computed(() => {
  const userId = Number(currentUser.value?.id);
  return Number.isFinite(userId) && userId > 0 ? userId : '';
});

const companiesEnabled = computed(() =>
  isFeatureEnabledonAccount.value(accountId.value, FEATURE_FLAGS.COMPANIES)
);
const currentAccountPermissions = computed(() => {
  const currentAccount = currentUser.value?.accounts?.find(
    account => Number(account.id) === Number(accountId.value)
  );

  return currentAccount?.permissions || [];
});
const canManageConversationDeals = computed(() => {
  return (
    isFeatureEnabledonAccount.value(accountId.value, FEATURE_FLAGS.CRM_DEALS) &&
    hasPermissions(CRM_DEAL_MANAGE_PERMISSIONS, currentAccountPermissions.value)
  );
});

const activePipelines = computed(() =>
  referencesStore.pipelines.filter(pipeline => pipeline.active !== false)
);

const defaultPipeline = computed(
  () =>
    activePipelines.value.find(pipeline => pipeline.default) ||
    activePipelines.value[0] ||
    null
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

const dealFieldDefinitions = computed(
  () => referencesStore.dealFieldDefinitions
);

const selectedContactOptionIds = computed(() =>
  [form.primaryContactId, ...form.contactIds].map(Number).filter(Boolean)
);

const selectedCompanyOptionIds = computed(() =>
  [form.companyId].map(Number).filter(Boolean)
);

const isPanelOpen = computed(() => props.modelValue);
const isConversationContext = computed(
  () =>
    isAConversationRoute(route.name, false, true) ||
    isAInboxViewRoute(route.name)
);
const shouldShowPanel = computed(
  () =>
    isConversationContext.value &&
    canManageConversationDeals.value &&
    !!props.currentChat?.id
);
const isEditingDeal = computed(() => !!selectedDeal.value);

const defaultDealCurrency = 'KZT';
const dealCurrencyOptions = ['KZT', 'USD', 'EUR', 'RUB'];

const formatErrorMessage = error => formatCrmErrorMessage(error, t);

function formatConversationDisplayLabel(value) {
  return value ? `#${value}` : '';
}

const buildContactOption = contact => {
  const primaryLabel =
    contact.name ||
    contact.phoneNumber ||
    contact.phone_number ||
    contact.email ||
    contact.identifier ||
    t('CRM.GENERAL.EMPTY_VALUE');
  const secondaryLabel = contact.name
    ? contact.phoneNumber ||
      contact.phone_number ||
      contact.email ||
      contact.identifier
    : '';

  return {
    label: [primaryLabel, secondaryLabel].filter(Boolean).join(' · '),
    value: Number(contact.id),
  };
};

const buildCompanyOption = company => ({
  label: company.name,
  value: Number(company.id),
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
  const resolvedDefaultPipeline = defaultPipeline.value;
  const defaultStage = defaultStageForPipeline(resolvedDefaultPipeline);

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

const closePanel = () => {
  emit('update:modelValue', false);
  emit('close');
};

const conversationDisplayId = computed(
  () => props.currentChat?.display_id || props.currentChat?.displayId || ''
);

const currentConversationReferenceId = computed(
  () => conversationDisplayId.value || props.currentChat?.id || ''
);

const conversationSender = computed(
  () => props.currentChat?.meta?.sender || {}
);

const buildPrefillDealTitle = () => {
  if (conversationSender.value?.name) {
    return t('CRM.DEALS.PREFILL.CONVERSATION_WITH_CONTACT', {
      contactName: conversationSender.value.name,
    });
  }

  if (conversationDisplayId.value) {
    return t('CRM.DEALS.PREFILL.CONVERSATION_GENERIC', {
      conversationId: conversationDisplayId.value,
    });
  }

  return '';
};

const buildConversationPrefill = () => {
  const contactId = Number(conversationSender.value?.id);
  const normalizedContactId =
    Number.isFinite(contactId) && contactId > 0 ? contactId : '';

  return {
    contactIds: normalizedContactId ? [normalizedContactId] : [],
    originatingConversationDisplayId: conversationDisplayId.value
      ? `#${conversationDisplayId.value}`
      : '',
    originatingConversationId: currentConversationReferenceId.value,
    ownerId: props.currentChat?.meta?.assignee?.id || currentUserId.value,
    primaryContactId: normalizedContactId,
    teamId: props.currentChat?.meta?.team?.id || '',
    title: buildPrefillDealTitle(),
  };
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

const ensureSelectedLookups = async ({ contactIds = [], companyId } = {}) => {
  const requests = [];
  const normalizedContactIds = contactIds
    .map(Number)
    .filter(contactId => Number.isFinite(contactId) && contactId > 0);

  normalizedContactIds.forEach(contactId => {
    if (
      contactOptions.value.some(
        option => Number(option.value) === Number(contactId)
      )
    ) {
      return;
    }

    requests.push(
      ContactAPI.show(contactId).then(response => {
        upsertContactOption(normalizePayload(response.data));
      })
    );
  });

  if (
    companyId &&
    companiesEnabled.value &&
    !companyOptions.value.some(
      option => Number(option.value) === Number(companyId)
    )
  ) {
    requests.push(
      CompanyAPI.show(companyId).then(response => {
        upsertCompanyOption(normalizePayload(response.data));
      })
    );
  }

  await Promise.all(requests);
};

const populateFormFromDeal = deal => {
  selectedDeal.value = deal;
  pendingCreateCustomFieldDefaultsHydration.value = false;

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
    ownerId: deal.ownerId ?? currentUserId.value,
    pipelineId: deal.pipelineId,
    primaryContactId: deal.primaryContactId ?? '',
    stageId: deal.stageId,
    teamId: deal.teamId ?? '',
    title: deal.title || '',
    winProbability: deal.winProbability ?? '',
  });
};

const findConversationDeal = async () => {
  if (!currentConversationReferenceId.value) {
    return null;
  }

  const { data } = await CrmDealsAPI.get({
    originating_conversation_id: currentConversationReferenceId.value,
  });

  const linkedDeals = normalizePayload(data)
    .filter(deal => {
      const conversationReferenceId =
        deal.originatingConversationDisplayId ?? deal.originatingConversationId;

      return (
        Number(conversationReferenceId) ===
        Number(currentConversationReferenceId.value)
      );
    })
    .sort((left, right) => {
      const leftTimestamp = Date.parse(left.updatedAt || left.createdAt || 0);
      const rightTimestamp = Date.parse(
        right.updatedAt || right.createdAt || 0
      );

      return rightTimestamp - leftTimestamp;
    });

  return linkedDeals[0] || null;
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

const buildPayload = () =>
  compactPayload({
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

    useAlert(
      selectedDeal.value
        ? t('CRM.DEALS.SUCCESS_UPDATED')
        : t('CRM.DEALS.SUCCESS_CREATED')
    );
    emit('saved', deal);
    closePanel();
  } catch (error) {
    useAlert(formatErrorMessage(error));
  } finally {
    ui.isSaving = false;
  }
};

const initializePanel = async () => {
  ui.isInitializing = true;
  contactOptions.value = [];
  companyOptions.value = [];
  selectedDeal.value = null;
  pendingCreateCustomFieldDefaultsHydration.value = true;

  try {
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

    await Promise.all([loadContacts(''), loadCompanies('')]);

    const linkedDeal = await findConversationDeal();

    if (linkedDeal) {
      populateFormFromDeal(linkedDeal);
      await ensureSelectedLookups({
        contactIds: form.contactIds,
        companyId: form.companyId,
      });
      return;
    }

    resetForm();

    const prefill = buildConversationPrefill();
    Object.assign(form, prefill);

    if (conversationSender.value?.id) {
      upsertContactOption(conversationSender.value);
    }

    await ensureSelectedLookups({
      contactIds: [prefill.primaryContactId],
      companyId: prefill.companyId,
    });
  } catch (error) {
    useAlert(formatErrorMessage(error));
    closePanel();
  } finally {
    ui.isInitializing = false;
  }
};

watch(
  () => isPanelOpen.value,
  async isOpen => {
    if (!isOpen) {
      return;
    }

    if (!shouldShowPanel.value) {
      closePanel();
      return;
    }

    await initializePanel();
  }
);

watch(
  [() => route.name, () => props.currentChat?.id],
  ([, conversationId], [, previousConversationId]) => {
    if (!props.modelValue) {
      return;
    }

    if (
      !shouldShowPanel.value ||
      (previousConversationId &&
        conversationId &&
        conversationId !== previousConversationId)
    ) {
      closePanel();
    }
  }
);

watch(
  dealFieldDefinitions,
  definitions => {
    if (
      !isPanelOpen.value ||
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

onBeforeRouteLeave(() => {
  if (props.modelValue) {
    closePanel();
  }
});
</script>

<template>
  <SchedulingSidePanel
    :model-value="modelValue && shouldShowPanel"
    :close-on-click-outside="false"
    width="xs"
    :title="
      isEditingDeal ? $t('CRM.DEALS.EDIT_TITLE') : $t('CRM.DEALS.CREATE_TITLE')
    "
    :description="$t('CRM.DEALS.DRAWER_DESCRIPTION')"
    :confirm-label="
      isEditingDeal ? $t('CRM.GENERAL.SAVE') : $t('CRM.GENERAL.CREATE')
    "
    :is-loading="ui.isSaving"
    :disable-confirm="
      ui.isInitializing ||
      !form.title.trim() ||
      !form.pipelineId ||
      !form.stageId
    "
    @update:model-value="emit('update:modelValue', $event)"
    @close="emit('close')"
    @confirm="saveDeal"
  >
    <div
      v-if="ui.isInitializing"
      class="flex items-center justify-center py-16"
    >
      <Spinner class="!h-8 !w-8" />
    </div>
    <div v-else class="grid gap-4">
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
        <div class="grid gap-4">
          <Input
            :label="$t('CRM.DEALS.FORM.TITLE')"
            :model-value="form.title"
            @update:model-value="form.title = $event"
          />
          <SchedulingSelectField
            :label="$t('CRM.DEALS.FORM.PIPELINE')"
            :model-value="form.pipelineId"
            :options="
              activePipelines.map(pipeline => ({
                label: pipeline.name,
                value: pipeline.id,
              }))
            "
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
        <div class="grid gap-4">
          <div class="grid gap-1">
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
                @click="createNewContactDialogRef?.dialogRef.open()"
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
                @click="createCompanyDialogRef?.dialogRef?.open()"
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

      <EntityTouchesCard
        v-if="selectedDeal?.id"
        remindable-type="Crm::Deal"
        :remindable-id="selectedDeal.id"
      />

      <SchedulingFormFieldGroup :framed="false">
        <TextArea
          :label="$t('CRM.DEALS.FORM.DESCRIPTION')"
          :model-value="form.description"
          auto-height
          @update:model-value="form.description = $event"
        />
      </SchedulingFormFieldGroup>
    </div>

    <CreateNewContactDialog
      ref="createNewContactDialogRef"
      @create="createContact"
    />
    <CreateCompanyDialog ref="createCompanyDialogRef" @create="createCompany" />
  </SchedulingSidePanel>
</template>
