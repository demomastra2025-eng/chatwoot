<script setup>
import { computed, onMounted, ref } from 'vue';
import { useI18n } from 'vue-i18n';
import { useStore, useMapGetter } from 'dashboard/composables/store';
import { useRouter } from 'vue-router';
import { useAlert } from 'dashboard/composables';

import Breadcrumb from 'dashboard/components-next/breadcrumb/Breadcrumb.vue';
import Button from 'dashboard/components-next/button/Button.vue';
import SettingsLayout from 'dashboard/routes/dashboard/settings/SettingsLayout.vue';
import AssignmentPolicyCard from 'dashboard/components-next/AssignmentPolicy/AssignmentPolicyCard/AssignmentPolicyCard.vue';
import ConfirmDeletePolicyDialog from './components/ConfirmDeletePolicyDialog.vue';

const store = useStore();
const { t } = useI18n();
const router = useRouter();

const agentAssignmentsPolicies = useMapGetter(
  'assignmentPolicies/getAssignmentPolicies'
);
const uiFlags = useMapGetter('assignmentPolicies/getUIFlags');

const confirmDeletePolicyDialogRef = ref(null);

const breadcrumbItems = computed(() => {
  const items = [
    {
      label: t('ASSIGNMENT_POLICY.INDEX.HEADER.TITLE'),
      routeName: 'assignment_policy_index',
    },
    {
      label: t('ASSIGNMENT_POLICY.AGENT_ASSIGNMENT_POLICY.INDEX.HEADER.TITLE'),
    },
  ];
  return items;
});

const handleBreadcrumbClick = item => {
  router.push({
    name: item.routeName,
  });
};

const onClickCreatePolicy = () => {
  router.push({
    name: 'agent_assignment_policy_create',
  });
};

const onClickEditPolicy = id => {
  router.push({
    name: 'agent_assignment_policy_edit',
    params: {
      id,
    },
  });
};

const handleDelete = id => {
  confirmDeletePolicyDialogRef.value.openDialog(id);
};

const handleDeletePolicy = async policyId => {
  try {
    await store.dispatch('assignmentPolicies/delete', policyId);
    useAlert(
      t(
        'ASSIGNMENT_POLICY.AGENT_ASSIGNMENT_POLICY.DELETE_POLICY.SUCCESS_MESSAGE'
      )
    );
    confirmDeletePolicyDialogRef.value.closeDialog();
  } catch (error) {
    const messageKey =
      error.response?.status === 409
        ? 'ASSIGNMENT_POLICY.AGENT_ASSIGNMENT_POLICY.DELETE_POLICY.SELECTED_WORKSPACE_POLICY_ERROR'
        : 'ASSIGNMENT_POLICY.AGENT_ASSIGNMENT_POLICY.DELETE_POLICY.ERROR_MESSAGE';
    useAlert(t(messageKey));
  }
};

onMounted(() => {
  store.dispatch('assignmentPolicies/get');
});
</script>

<template>
  <SettingsLayout
    :is-loading="uiFlags.isFetching"
    :no-records-found="agentAssignmentsPolicies.length === 0"
    :no-records-message="
      $t('ASSIGNMENT_POLICY.AGENT_ASSIGNMENT_POLICY.INDEX.NO_RECORDS_FOUND')
    "
  >
    <template #header>
      <div class="flex items-center gap-2 w-full justify-between min-h-10">
        <Breadcrumb :items="breadcrumbItems" @click="handleBreadcrumbClick" />
        <Button icon="i-lucide-plus" md @click="onClickCreatePolicy">
          {{
            $t(
              'ASSIGNMENT_POLICY.AGENT_ASSIGNMENT_POLICY.INDEX.HEADER.CREATE_POLICY'
            )
          }}
        </Button>
      </div>
    </template>
    <template #body>
      <div class="flex flex-col gap-4 pt-4">
        <AssignmentPolicyCard
          v-for="policy in agentAssignmentsPolicies"
          :key="policy.id"
          :id="policy.id"
          :name="policy.name"
          :description="policy.description"
          :assignment-order="policy.assignmentOrder"
          :conversation-priority="policy.conversationPriority"
          :assignment-delay-minutes="policy.assignmentDelayMinutes"
          :max-open-conversations="policy.maxOpenConversations"
          :assign-online-only="policy.assignOnlineOnly"
          :assign-pending-conversations="policy.assignPendingConversations"
          :monthly-new-client-quota="policy.monthlyNewClientQuota"
          :sticky-owner-enabled="policy.stickyOwnerEnabled"
          :sticky-owner-duration-days="policy.stickyOwnerDurationDays"
          @edit="onClickEditPolicy"
          @delete="handleDelete"
        />
      </div>
    </template>
    <ConfirmDeletePolicyDialog
      ref="confirmDeletePolicyDialogRef"
      @delete="handleDeletePolicy"
    />
  </SettingsLayout>
</template>
