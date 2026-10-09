<script setup>
import { computed, ref, watch } from 'vue';
import { useI18n } from 'vue-i18n';
import camelcaseKeys from 'camelcase-keys';
import { useAlert } from 'dashboard/composables';
import { useAccount } from 'dashboard/composables/useAccount';
import { usePolicy } from 'dashboard/composables/usePolicy';
import assignmentPoliciesAPI from 'dashboard/api/assignmentPolicies';
import Button from 'dashboard/components-next/button/Button.vue';
import Select from 'dashboard/components-next/select/Select.vue';
import SectionLayout from './SectionLayout.vue';

const { t } = useI18n();
const { currentAccount, accountId, updateAccount } = useAccount();
const { checkPermissions } = usePolicy();

const availablePolicies = ref([]);
const selectedPolicyId = ref('');
const isFetching = ref(false);
const fetchFailed = ref(false);
const isSaving = ref(false);
const isWorkspaceAdmin = computed(() => checkPermissions(['administrator']));
const savedPolicyId = computed(
  () => currentAccount.value?.settings?.conversation_assignment_policy_id
);
const hasUnavailableSavedPolicy = computed(
  () =>
    !isFetching.value &&
    !fetchFailed.value &&
    savedPolicyId.value !== null &&
    savedPolicyId.value !== undefined &&
    !availablePolicies.value.some(
      policy =>
        String(policy.id) === String(savedPolicyId.value) && policy.enabled
    )
);
const isDirty = computed(
  () => selectedPolicyId.value !== String(savedPolicyId.value ?? '')
);
const statusMessage = computed(() => {
  if (fetchFailed.value) {
    return t(
      'GENERAL_SETTINGS.CONVERSATIONS.ASSIGNMENT_POLICY_UNVERIFIED_NOTICE'
    );
  }

  if (hasUnavailableSavedPolicy.value) {
    return t('GENERAL_SETTINGS.CONVERSATIONS.ASSIGNMENT_POLICY_UNAVAILABLE');
  }

  return savedPolicyId.value
    ? t('GENERAL_SETTINGS.CONVERSATIONS.ASSIGNMENT_POLICY_SELECTED_NOTICE')
    : t('GENERAL_SETTINGS.CONVERSATIONS.ASSIGNMENT_POLICY_LEGACY_NOTICE');
});

const loadPolicies = async requestedAccountId => {
  if (!requestedAccountId) return;

  isFetching.value = true;
  fetchFailed.value = false;
  try {
    const response = await assignmentPoliciesAPI.get();
    if (String(accountId.value) !== String(requestedAccountId)) return;

    availablePolicies.value = camelcaseKeys(response.data, { deep: true });
  } catch {
    if (String(accountId.value) === String(requestedAccountId)) {
      availablePolicies.value = [];
      fetchFailed.value = true;
    }
  } finally {
    if (String(accountId.value) === String(requestedAccountId)) {
      isFetching.value = false;
    }
  }
};

const retryLoadPolicies = () => loadPolicies(accountId.value);

watch(
  accountId,
  requestedAccountId => {
    availablePolicies.value = [];
    selectedPolicyId.value = '';
    loadPolicies(requestedAccountId);
  },
  { immediate: true }
);

watch(
  savedPolicyId,
  value => {
    selectedPolicyId.value = String(value ?? '');
  },
  { immediate: true }
);

const savePolicy = async () => {
  if (!isWorkspaceAdmin.value || !isDirty.value || isSaving.value) return;

  const requestAccountId = accountId.value;
  const policyId = selectedPolicyId.value
    ? Number(selectedPolicyId.value)
    : null;
  isSaving.value = true;
  try {
    await updateAccount(
      { conversation_assignment_policy_id: policyId },
      { silent: true }
    );
    if (String(accountId.value) === String(requestAccountId)) {
      useAlert(
        t('GENERAL_SETTINGS.CONVERSATIONS.ASSIGNMENT_POLICY_UPDATE_SUCCESS')
      );
    }
  } catch {
    if (String(accountId.value) === String(requestAccountId)) {
      useAlert(
        t('GENERAL_SETTINGS.CONVERSATIONS.ASSIGNMENT_POLICY_UPDATE_ERROR')
      );
    }
  } finally {
    isSaving.value = false;
  }
};
</script>

<template>
  <SectionLayout
    :title="t('GENERAL_SETTINGS.CONVERSATIONS.ASSIGNMENT_POLICY_TITLE')"
    :description="
      t('GENERAL_SETTINGS.CONVERSATIONS.ASSIGNMENT_POLICY_DESCRIPTION')
    "
  >
    <div class="flex flex-col gap-4">
      <label class="flex flex-col gap-2 text-sm font-medium text-n-slate-12">
        {{ t('GENERAL_SETTINGS.CONVERSATIONS.ASSIGNMENT_POLICY_LABEL') }}
        <Select
          v-model="selectedPolicyId"
          data-test="workspace-assignment-policy-select"
          :disabled="!isWorkspaceAdmin || isFetching || isSaving"
        >
          <option value="">
            {{
              t('GENERAL_SETTINGS.CONVERSATIONS.ASSIGNMENT_POLICY_PLACEHOLDER')
            }}
          </option>
          <option
            v-if="hasUnavailableSavedPolicy || (fetchFailed && savedPolicyId)"
            :value="String(savedPolicyId)"
          >
            {{
              t(
                'GENERAL_SETTINGS.CONVERSATIONS.ASSIGNMENT_POLICY_UNAVAILABLE_OPTION'
              )
            }}
          </option>
          <option
            v-for="policy in availablePolicies.filter(item => item.enabled)"
            :key="policy.id"
            :value="String(policy.id)"
          >
            {{ policy.name }}
          </option>
        </Select>
      </label>

      <p class="m-0 text-sm text-n-slate-11" role="status">
        {{ statusMessage }}
      </p>
      <p class="m-0 text-sm text-n-slate-11">
        {{
          t('GENERAL_SETTINGS.CONVERSATIONS.ASSIGNMENT_POLICY_PHONE_LINE_NOTE')
        }}
      </p>
      <div v-if="fetchFailed" class="flex items-center gap-3">
        <p class="m-0 text-sm text-n-ruby-11" role="alert">
          {{ t('GENERAL_SETTINGS.CONVERSATIONS.ASSIGNMENT_POLICY_LOAD_ERROR') }}
        </p>
        <Button
          sm
          slate
          faded
          :label="t('GENERAL_SETTINGS.CONVERSATIONS.ASSIGNMENT_POLICY_RETRY')"
          @click="retryLoadPolicies"
        />
      </div>
      <div v-if="isWorkspaceAdmin" class="flex justify-end">
        <Button
          data-test="workspace-assignment-policy-save"
          :label="t('GENERAL_SETTINGS.CONVERSATIONS.ASSIGNMENT_POLICY_SAVE')"
          :disabled="!isDirty || isFetching || isSaving"
          :is-loading="isSaving"
          @click="savePolicy"
        />
      </div>
    </div>
  </SectionLayout>
</template>
