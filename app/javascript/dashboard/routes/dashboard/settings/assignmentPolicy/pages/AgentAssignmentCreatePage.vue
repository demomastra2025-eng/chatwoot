<script setup>
import { computed, onMounted, ref } from 'vue';
import { useI18n } from 'vue-i18n';
import { useStore, useMapGetter } from 'dashboard/composables/store';
import { useRoute, useRouter } from 'vue-router';
import { useAlert } from 'dashboard/composables';
import { labelDisplayTitle } from 'dashboard/helper/labels';

import Breadcrumb from 'dashboard/components-next/breadcrumb/Breadcrumb.vue';
import SettingsLayout from 'dashboard/routes/dashboard/settings/SettingsLayout.vue';
import AssignmentPolicyForm from 'dashboard/routes/dashboard/settings/assignmentPolicy/pages/components/AgentAssignmentPolicyForm.vue';

const route = useRoute();
const router = useRouter();
const store = useStore();
const { t } = useI18n();

const formRef = ref(null);
const uiFlags = useMapGetter('assignmentPolicies/getUIFlags');
const labelsList = useMapGetter('labels/getLabels');

const allLabels = computed(() =>
  (labelsList.value || []).map(label => ({
    ...label,
    name: labelDisplayTitle(label),
    display_title: labelDisplayTitle(label),
  }))
);

const breadcrumbItems = computed(() => [
    {
      label: t('ASSIGNMENT_POLICY.AGENT_ASSIGNMENT_POLICY.INDEX.HEADER.TITLE'),
      routeName: 'agent_assignment_policy_index',
    },
    {
      label: t('ASSIGNMENT_POLICY.AGENT_ASSIGNMENT_POLICY.CREATE.HEADER.TITLE'),
    },
  ]);

const handleBreadcrumbClick = item =>
  router.push({
    name: item.routeName,
    params: { accountId: route.params.accountId },
  });

const handleSubmit = async formState => {
  try {
    const policy = await store.dispatch('assignmentPolicies/create', formState);
    useAlert(
      t('ASSIGNMENT_POLICY.AGENT_ASSIGNMENT_POLICY.CREATE.API.SUCCESS_MESSAGE')
    );
    formRef.value?.resetForm();

    router.push({
      name: 'agent_assignment_policy_edit',
      params: {
        accountId: route.params.accountId,
        id: policy.id,
      },
    });
  } catch (error) {
    useAlert(
      t('ASSIGNMENT_POLICY.AGENT_ASSIGNMENT_POLICY.CREATE.API.ERROR_MESSAGE')
    );
  }
};

onMounted(() => {
  if (!labelsList.value?.length) store.dispatch('labels/get');
});
</script>

<template>
  <SettingsLayout class="w-full max-w-3xl ltr:mr-auto rtl:ml-auto">
    <template #header>
      <div class="flex items-center gap-2 w-full justify-between mb-4 min-h-10">
        <Breadcrumb :items="breadcrumbItems" @click="handleBreadcrumbClick" />
      </div>
    </template>

    <template #body>
      <AssignmentPolicyForm
        ref="formRef"
        mode="CREATE"
        :is-loading="uiFlags.isCreating"
        :label-list="allLabels"
        @submit="handleSubmit"
      />
    </template>
  </SettingsLayout>
</template>
