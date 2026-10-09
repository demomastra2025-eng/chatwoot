<script setup>
import { computed, onMounted, watch } from 'vue';
import { useI18n } from 'vue-i18n';
import { useStore, useMapGetter } from 'dashboard/composables/store';
import { useRoute, useRouter } from 'vue-router';
import { useAlert } from 'dashboard/composables';
import { labelDisplayTitle } from 'dashboard/helper/labels';
import {
  ROUND_ROBIN,
  EARLIEST_CREATED,
  DEFAULT_ASSIGNMENT_DELAY_MINUTES,
  DEFAULT_STICKY_OWNER_DURATION_DAYS,
} from 'dashboard/routes/dashboard/settings/assignmentPolicy/constants';

import Breadcrumb from 'dashboard/components-next/breadcrumb/Breadcrumb.vue';
import SettingsLayout from 'dashboard/routes/dashboard/settings/SettingsLayout.vue';
import AssignmentPolicyForm from 'dashboard/routes/dashboard/settings/assignmentPolicy/pages/components/AgentAssignmentPolicyForm.vue';

const BASE_KEY = 'ASSIGNMENT_POLICY.AGENT_ASSIGNMENT_POLICY';

const { t } = useI18n();
const route = useRoute();
const router = useRouter();
const store = useStore();

const uiFlags = useMapGetter('assignmentPolicies/getUIFlags');
const labelsList = useMapGetter('labels/getLabels');
const selectedPolicyById = useMapGetter(
  'assignmentPolicies/getAssignmentPolicyById'
);

const routeId = computed(() => route.params.id);
const selectedPolicy = computed(() => selectedPolicyById.value(routeId.value));

const breadcrumbItems = computed(() => {
  return [
    {
      label: t(`${BASE_KEY}.INDEX.HEADER.TITLE`),
      routeName: 'agent_assignment_policy_index',
    },
    { label: t(`${BASE_KEY}.EDIT.HEADER.TITLE`) },
  ];
});

const allLabels = computed(() =>
  (labelsList.value || []).map(label => ({
    ...label,
    name: labelDisplayTitle(label),
    display_title: labelDisplayTitle(label),
  }))
);

const formData = computed(() => ({
  name: selectedPolicy.value?.name || '',
  description: selectedPolicy.value?.description || '',
  enabled: selectedPolicy.value?.enabled ?? true,
  assignmentOrder: selectedPolicy.value?.assignmentOrder || ROUND_ROBIN,
  conversationPriority:
    selectedPolicy.value?.conversationPriority || EARLIEST_CREATED,
  fairDistributionLimit: selectedPolicy.value?.fairDistributionLimit || 100,
  fairDistributionWindow: selectedPolicy.value?.fairDistributionWindow || 3600,
  assignmentDelayMinutes:
    selectedPolicy.value?.assignmentDelayMinutes ??
    DEFAULT_ASSIGNMENT_DELAY_MINUTES,
  maxOpenConversations: selectedPolicy.value?.maxOpenConversations ?? null,
  assignOnlineOnly: selectedPolicy.value?.assignOnlineOnly ?? true,
  assignPendingConversations:
    selectedPolicy.value?.assignPendingConversations ?? false,
  exclusionRules: {
    excludedLabels: [
      ...(selectedPolicy.value?.exclusionRules?.excludedLabels || []),
    ],
    excludeOlderThanMinutes:
      selectedPolicy.value?.exclusionRules?.excludeOlderThanMinutes ?? null,
  },
  monthlyNewClientQuota: selectedPolicy.value?.monthlyNewClientQuota ?? null,
  stickyOwnerEnabled: selectedPolicy.value?.stickyOwnerEnabled || false,
  stickyOwnerDurationDays:
    selectedPolicy.value?.stickyOwnerDurationDays ??
    DEFAULT_STICKY_OWNER_DURATION_DAYS,
}));

const handleBreadcrumbClick = ({ routeName }) => {
  router.push({ name: routeName, params: { accountId: route.params.accountId } });
};

const handleSubmit = async formState => {
  try {
    await store.dispatch('assignmentPolicies/update', {
      id: selectedPolicy.value?.id,
      ...formState,
    });
    useAlert(t(`${BASE_KEY}.EDIT.API.SUCCESS_MESSAGE`));
  } catch (error) {
    const messageKey =
      error.response?.status === 409
        ? `${BASE_KEY}.EDIT.SELECTED_WORKSPACE_POLICY_ERROR`
        : `${BASE_KEY}.EDIT.API.ERROR_MESSAGE`;
    useAlert(t(messageKey));
  }
};

const fetchPolicyData = async () => {
  if (!routeId.value) return;

  // Fetch policy if not available
  if (!selectedPolicy.value?.id)
    await store.dispatch('assignmentPolicies/show', routeId.value);
};

watch(routeId, fetchPolicyData, { immediate: true });
onMounted(() => {
  if (!labelsList.value?.length) store.dispatch('labels/get');
});
</script>

<template>
  <SettingsLayout
    :is-loading="uiFlags.isFetchingItem"
    class="w-full max-w-3xl ltr:mr-auto rtl:ml-auto"
  >
    <template #header>
      <div class="flex items-center gap-2 w-full justify-between mb-4 min-h-10">
        <Breadcrumb :items="breadcrumbItems" @click="handleBreadcrumbClick" />
      </div>
    </template>

    <template #body>
      <AssignmentPolicyForm
        :key="routeId"
        mode="EDIT"
        :initial-data="formData"
        :label-list="allLabels"
        :is-loading="uiFlags.isUpdating"
        @submit="handleSubmit"
      />
    </template>
  </SettingsLayout>
</template>
