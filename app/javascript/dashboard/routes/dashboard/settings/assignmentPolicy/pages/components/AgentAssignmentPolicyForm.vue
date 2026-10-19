<script setup>
import { computed, onMounted, reactive, ref, watch } from 'vue';
import { useI18n } from 'vue-i18n';
import { useRoute } from 'vue-router';
import { useStore, useMapGetter } from 'dashboard/composables/store';
import BaseInfo from 'dashboard/components-next/AssignmentPolicy/components/BaseInfo.vue';
import RadioCard from 'dashboard/components-next/radioCard/RadioCard.vue';
import FairDistribution from 'dashboard/components-next/AssignmentPolicy/components/FairDistribution.vue';
import LoadControls from 'dashboard/components-next/AssignmentPolicy/components/LoadControls.vue';
import ExclusionRules from 'dashboard/components-next/AssignmentPolicy/components/ExclusionRules.vue';
import WithLabel from 'v3/components/Form/WithLabel.vue';
import Button from 'dashboard/components-next/button/Button.vue';
import {
  OPTIONS,
  ROUND_ROBIN,
  EARLIEST_CREATED,
  DEFAULT_FAIR_DISTRIBUTION_LIMIT,
  DEFAULT_FAIR_DISTRIBUTION_WINDOW,
  DEFAULT_ASSIGNMENT_DELAY_MINUTES,
  DEFAULT_STICKY_OWNER_DURATION_DAYS,
} from 'dashboard/routes/dashboard/settings/assignmentPolicy/constants';

const props = defineProps({
  initialData: {
    type: Object,
    default: () => ({
      name: '',
      description: '',
      assignmentOrder: ROUND_ROBIN,
      conversationPriority: EARLIEST_CREATED,
      fairDistributionLimit: DEFAULT_FAIR_DISTRIBUTION_LIMIT,
      fairDistributionWindow: DEFAULT_FAIR_DISTRIBUTION_WINDOW,
      assignmentDelayMinutes: DEFAULT_ASSIGNMENT_DELAY_MINUTES,
      maxOpenConversations: null,
      assignOnlineOnly: true,
      assignPendingConversations: false,
      exclusionRules: {
        excludedLabels: [],
        excludeOlderThanMinutes: null,
        excludedUserIds: [],
      },
      monthlyNewClientQuota: null,
      stickyOwnerEnabled: false,
      stickyOwnerDurationDays: DEFAULT_STICKY_OWNER_DURATION_DAYS,
    }),
  },
  mode: {
    type: String,
    required: true,
    validator: value => ['CREATE', 'EDIT'].includes(value),
  },
  labelList: {
    type: Array,
    default: () => [],
  },
  agentList: {
    type: Array,
    default: () => [],
  },
  isLoading: {
    type: Boolean,
    default: false,
  },
});

const emit = defineEmits(['submit', 'validationChange']);

const { t } = useI18n();
const route = useRoute();
const store = useStore();

const accountId = computed(() => Number(route.params.accountId));
const isFeatureEnabledonAccount = useMapGetter(
  'accounts/isFeatureEnabledonAccount'
);
const storeAgents = useMapGetter('agents/getAgents');

const BASE_KEY = 'ASSIGNMENT_POLICY.AGENT_ASSIGNMENT_POLICY';

const state = reactive({
  name: '',
  description: '',
  enabled: true,
  assignmentOrder: ROUND_ROBIN,
  conversationPriority: EARLIEST_CREATED,
  fairDistributionLimit: DEFAULT_FAIR_DISTRIBUTION_LIMIT,
  fairDistributionWindow: DEFAULT_FAIR_DISTRIBUTION_WINDOW,
  assignmentDelayMinutes: DEFAULT_ASSIGNMENT_DELAY_MINUTES,
  maxOpenConversations: null,
  assignOnlineOnly: true,
  assignPendingConversations: false,
  exclusionRules: {
    excludedLabels: [],
    excludeOlderThanMinutes: null,
    excludedUserIds: [],
  },
  monthlyNewClientQuota: null,
  stickyOwnerEnabled: false,
  stickyOwnerDurationDays: DEFAULT_STICKY_OWNER_DURATION_DAYS,
});

const validationState = ref({
  isValid: false,
});

const availableAgents = computed(() => {
  const rawAgents = props.agentList?.length
    ? props.agentList
    : storeAgents.value || [];

  return [...rawAgents].sort((a, b) =>
    String(a.name || a.email || '').localeCompare(
      String(b.name || b.email || ''),
      'ru'
    )
  );
});

const isAgentIncluded = agentId => {
  const normalizedId = Number(agentId);
  return !(state.exclusionRules.excludedUserIds || []).some(
    id => Number(id) === normalizedId
  );
};

const toggleAgent = agentId => {
  const normalizedId = Number(agentId);
  const currentExcluded = (state.exclusionRules.excludedUserIds || []).map(id =>
    Number(id)
  );

  if (currentExcluded.includes(normalizedId)) {
    state.exclusionRules.excludedUserIds = currentExcluded.filter(
      id => id !== normalizedId
    );
  } else {
    state.exclusionRules.excludedUserIds = [...currentExcluded, normalizedId];
  }
};

const selectAllAgents = () => {
  state.exclusionRules.excludedUserIds = [];
};

const clearAllAgents = () => {
  state.exclusionRules.excludedUserIds = availableAgents.value.map(agent =>
    Number(agent.id)
  );
};

const createOption = (
  type,
  key,
  stateKey,
  disabled = false,
  disabledMessage = '',
  disabledLabel = ''
) => ({
  key,
  label: t(`${BASE_KEY}.FORM.${type}.${key.toUpperCase()}.LABEL`),
  description: t(`${BASE_KEY}.FORM.${type}.${key.toUpperCase()}.DESCRIPTION`),
  isActive: state[stateKey] === key,
  disabled,
  disabledMessage,
  disabledLabel,
});

const assignmentOrderOptions = computed(() => {
  const hasAdvancedAssignment = isFeatureEnabledonAccount.value(
    accountId.value,
    'advanced_assignment'
  );

  return OPTIONS.ORDER.map(key => {
    const isBalanced = key === 'balanced';
    const disabled = isBalanced && !hasAdvancedAssignment;
    const disabledMessage = disabled
      ? t(`${BASE_KEY}.FORM.ASSIGNMENT_ORDER.BALANCED.PREMIUM_MESSAGE`)
      : '';
    const disabledLabel = disabled
      ? t(`${BASE_KEY}.FORM.ASSIGNMENT_ORDER.BALANCED.PREMIUM_BADGE`)
      : '';

    return createOption(
      'ASSIGNMENT_ORDER',
      key,
      'assignmentOrder',
      disabled,
      disabledMessage,
      disabledLabel
    );
  });
});

const assignmentPriorityOptions = computed(() =>
  OPTIONS.PRIORITY.map(key =>
    createOption('ASSIGNMENT_PRIORITY', key, 'conversationPriority')
  )
);

const radioSections = computed(() => [
  {
    key: 'assignmentOrder',
    label: t(`${BASE_KEY}.FORM.ASSIGNMENT_ORDER.LABEL`),
    options: assignmentOrderOptions.value,
  },
  {
    key: 'conversationPriority',
    label: t(`${BASE_KEY}.FORM.ASSIGNMENT_PRIORITY.LABEL`),
    options: assignmentPriorityOptions.value,
  },
]);

const buttonLabel = computed(() =>
  t(`${BASE_KEY}.${props.mode.toUpperCase()}.${props.mode}_BUTTON`)
);

const statusPlaceholder = computed(() =>
  t(`${BASE_KEY}.FORM.STATUS.${state.enabled ? 'ACTIVE' : 'INACTIVE'}`)
);

const handleValidationChange = validation => {
  validationState.value = validation;
  emit('validationChange', validation);
};

const resetForm = () => {
  Object.assign(state, {
    name: '',
    description: '',
    enabled: true,
    assignmentOrder: ROUND_ROBIN,
    conversationPriority: EARLIEST_CREATED,
    fairDistributionLimit: DEFAULT_FAIR_DISTRIBUTION_LIMIT,
    fairDistributionWindow: DEFAULT_FAIR_DISTRIBUTION_WINDOW,
    assignmentDelayMinutes: DEFAULT_ASSIGNMENT_DELAY_MINUTES,
    maxOpenConversations: null,
    assignOnlineOnly: true,
    assignPendingConversations: false,
    exclusionRules: {
      excludedLabels: [],
      excludeOlderThanMinutes: null,
      excludedUserIds: [],
    },
    monthlyNewClientQuota: null,
    stickyOwnerEnabled: false,
    stickyOwnerDurationDays: DEFAULT_STICKY_OWNER_DURATION_DAYS,
  });
};

const handleSubmit = () => {
  emit('submit', {
    ...state,
    exclusionRules: {
      excludedLabels: [...(state.exclusionRules.excludedLabels || [])],
      excludeOlderThanMinutes:
        state.exclusionRules.excludeOlderThanMinutes ?? null,
      excludedUserIds: [...(state.exclusionRules.excludedUserIds || [])],
    },
  });
};

watch(
  () => props.initialData,
  newData => {
    if (!newData) return;
    Object.assign(state, {
      ...newData,
      exclusionRules: {
        excludedLabels: [...(newData.exclusionRules?.excludedLabels || [])],
        excludeOlderThanMinutes:
          newData.exclusionRules?.excludeOlderThanMinutes ?? null,
        excludedUserIds: (newData.exclusionRules?.excludedUserIds || []).map(
          id => Number(id)
        ),
      },
    });
  },
  { immediate: true, deep: true }
);

onMounted(() => {
  if (!props.agentList?.length && !storeAgents.value?.length) {
    store.dispatch('agents/get');
  }
});

defineExpose({
  resetForm,
});
</script>

<template>
  <form @submit.prevent="handleSubmit">
    <div class="flex flex-col gap-4 divide-y divide-n-weak mb-4">
      <BaseInfo
        v-model:policy-name="state.name"
        v-model:description="state.description"
        v-model:enabled="state.enabled"
        :name-label="t(`${BASE_KEY}.FORM.NAME.LABEL`)"
        :name-placeholder="t(`${BASE_KEY}.FORM.NAME.PLACEHOLDER`)"
        :description-label="t(`${BASE_KEY}.FORM.DESCRIPTION.LABEL`)"
        :description-placeholder="t(`${BASE_KEY}.FORM.DESCRIPTION.PLACEHOLDER`)"
        :status-label="t(`${BASE_KEY}.FORM.STATUS.LABEL`)"
        :status-placeholder="statusPlaceholder"
        @validation-change="handleValidationChange"
      />

      <div class="flex flex-col items-center">
        <div
          v-for="section in radioSections"
          :key="section.key"
          class="py-4 flex flex-col items-start gap-3 w-full"
        >
          <WithLabel
            :label="section.label"
            name="assignmentPolicy"
            class="w-full flex items-start flex-col gap-3"
          >
            <div class="grid grid-cols-1 xs:grid-cols-2 gap-4 w-full">
              <RadioCard
                v-for="option in section.options"
                :id="option.key"
                :key="option.key"
                :name="section.key"
                :label="option.label"
                :description="option.description"
                :is-active="option.isActive"
                :disabled="option.disabled"
                :disabled-label="option.disabledLabel"
                :disabled-message="option.disabledMessage"
                @select="state[section.key] = $event"
              />
            </div>
          </WithLabel>
        </div>
      </div>

      <div class="pt-4 pb-2 flex-col flex gap-4">
        <div class="flex flex-col items-start gap-1 py-1">
          <label class="text-sm font-medium text-n-slate-12 py-1">
            {{ t(`${BASE_KEY}.FORM.FAIR_DISTRIBUTION.LABEL`) }}
          </label>
          <p class="mb-0 text-n-slate-11 text-sm">
            {{ t(`${BASE_KEY}.FORM.FAIR_DISTRIBUTION.DESCRIPTION`) }}
          </p>
        </div>
        <FairDistribution
          v-model:fair-distribution-limit="state.fairDistributionLimit"
          v-model:fair-distribution-window="state.fairDistributionWindow"
          v-model:window-unit="state.windowUnit"
        />
      </div>

      <ExclusionRules
        v-model:excluded-labels="state.exclusionRules.excludedLabels"
        v-model:exclude-older-than-minutes="
          state.exclusionRules.excludeOlderThanMinutes
        "
        :tags-list="labelList"
      />

      <div
        class="pt-4 pb-2 flex-col flex gap-3"
        data-test="assignment-policy-agents-section"
      >
        <div class="flex items-start justify-between gap-2 py-1">
          <div class="flex flex-col items-start gap-1">
            <label class="text-sm font-medium text-n-slate-12 py-1">
              {{ t(`${BASE_KEY}.FORM.AGENTS.LABEL`) }}
            </label>
            <p class="mb-0 text-n-slate-11 text-sm">
              {{ t(`${BASE_KEY}.FORM.AGENTS.DESCRIPTION`) }}
            </p>
          </div>
          <div
            v-if="availableAgents.length"
            class="flex shrink-0 items-center gap-2 pt-1"
          >
            <button
              type="button"
              data-test="assignment-policy-select-all-agents"
              class="text-xs font-medium text-n-brand hover:underline"
              @click="selectAllAgents"
            >
              {{ t(`${BASE_KEY}.FORM.AGENTS.SELECT_ALL`) }}
            </button>
            <span class="text-xs text-n-slate-9">·</span>
            <button
              type="button"
              data-test="assignment-policy-clear-all-agents"
              class="text-xs font-medium text-n-slate-11 hover:underline"
              @click="clearAllAgents"
            >
              {{ t(`${BASE_KEY}.FORM.AGENTS.CLEAR_ALL`) }}
            </button>
          </div>
        </div>

        <p
          v-if="!availableAgents.length"
          class="m-0 text-sm text-n-slate-11"
        >
          {{ t(`${BASE_KEY}.FORM.AGENTS.EMPTY_STATE`) }}
        </p>

        <div
          v-else
          class="grid grid-cols-1 gap-2 sm:grid-cols-2 rounded-xl border border-n-weak p-3"
        >
          <label
            v-for="agent in availableAgents"
            :key="agent.id"
            class="flex items-center justify-between gap-2 rounded-lg px-2 py-1.5 text-sm text-n-slate-12 hover:bg-n-alpha-1 cursor-pointer"
          >
            <span class="flex items-center gap-2 min-w-0">
              <input
                type="checkbox"
                :data-test="`assignment-policy-agent-${agent.id}`"
                :checked="isAgentIncluded(agent.id)"
                @change="toggleAgent(agent.id)"
              />
              <span class="truncate">{{ agent.name || agent.email }}</span>
            </span>
            <span
              class="shrink-0 rounded-md bg-n-alpha-2 px-2 py-0.5 text-xs text-n-slate-11"
            >
              {{
                agent.role === 'administrator'
                  ? t(`${BASE_KEY}.FORM.AGENTS.ROLE_ADMIN`)
                  : t(`${BASE_KEY}.FORM.AGENTS.ROLE_AGENT`)
              }}
            </span>
          </label>
        </div>
      </div>

      <div class="pt-4 pb-2 flex-col flex gap-4">
        <div class="flex flex-col items-start gap-1 py-1">
          <label class="text-sm font-medium text-n-slate-12 py-1">
            {{
              t(
                'ASSIGNMENT_POLICY.AGENT_ASSIGNMENT_POLICY.FORM.LOAD_CONTROLS.LABEL'
              )
            }}
          </label>
          <p class="mb-0 text-n-slate-11 text-sm">
            {{
              t(
                'ASSIGNMENT_POLICY.AGENT_ASSIGNMENT_POLICY.FORM.LOAD_CONTROLS.DESCRIPTION'
              )
            }}
          </p>
        </div>
        <LoadControls
          v-model:assignment-delay-minutes="state.assignmentDelayMinutes"
          v-model:max-open-conversations="state.maxOpenConversations"
          v-model:assign-online-only="state.assignOnlineOnly"
          v-model:assign-pending-conversations="
            state.assignPendingConversations
          "
          v-model:monthly-new-client-quota="state.monthlyNewClientQuota"
          v-model:sticky-owner-enabled="state.stickyOwnerEnabled"
          v-model:sticky-owner-duration-days="state.stickyOwnerDurationDays"
        />
      </div>
    </div>

    <Button
      type="submit"
      :label="buttonLabel"
      :disabled="!validationState.isValid || isLoading"
      :is-loading="isLoading"
    />
  </form>
</template>
