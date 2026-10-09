<script setup>
import { ref, computed, watch, onMounted } from 'vue';
import { useStore } from 'vuex';
import { useRoute, useRouter } from 'vue-router';
import { useVuelidate } from '@vuelidate/core';
import { minValue } from '@vuelidate/validators';
import { useAlert } from 'dashboard/composables';
import { useConfig } from 'dashboard/composables/useConfig';
import SettingsFieldSection from 'dashboard/components-next/Settings/SettingsFieldSection.vue';
import SettingsAccordion from 'dashboard/components-next/Settings/SettingsAccordion.vue';
import NextButton from 'dashboard/components-next/button/Button.vue';
import SettingsToggleSection from 'dashboard/components-next/Settings/SettingsToggleSection.vue';
import TagInput from 'dashboard/components-next/taginput/TagInput.vue';
import { useI18n } from 'vue-i18n';

const props = defineProps({
  inbox: {
    type: Object,
    default: () => ({}),
  },
});

const store = useStore();
const route = useRoute();
const router = useRouter();
const { t } = useI18n();
const { isEnterprise } = useConfig();

const selectedAgentIds = ref([]);
const isAgentListUpdating = ref(false);
const enableAutoAssignment = ref(false);
const maxAssignmentLimit = ref(null);

const agentList = computed(() => store.getters['agents/getAgents']);

const selectedAgentNames = computed(() =>
  selectedAgentIds.value.map(
    id => agentList.value.find(a => a.id === id)?.name ?? ''
  )
);

const agentMenuItems = computed(() =>
  agentList.value
    .filter(({ id }) => !selectedAgentIds.value.includes(id))
    .map(({ id, name, thumbnail, avatar_url }) => ({
      label: name,
      value: id,
      action: 'select',
      thumbnail: { name, src: thumbnail || avatar_url || '' },
    }))
);

const handleAgentAdd = ({ value }) => {
  if (!selectedAgentIds.value.includes(value)) {
    selectedAgentIds.value.push(value);
  }
};

const handleAgentRemove = index => {
  selectedAgentIds.value.splice(index, 1);
};

const isFeatureEnabled = feature => {
  const accountId = Number(route.params.accountId);
  return store.getters['accounts/isFeatureEnabledonAccount'](
    accountId,
    feature
  );
};

const hasAdvancedAssignment = computed(() => {
  return isFeatureEnabled('advanced_assignment');
});

const hasAssignmentV2 = computed(() => {
  return isFeatureEnabled('assignment_v2');
});

const showAdvancedAssignmentUI = computed(() => {
  return hasAdvancedAssignment.value && hasAssignmentV2.value;
});

// Vuelidate validation rules
const rules = {
  maxAssignmentLimit: {
    minValue: minValue(1),
  },
};

const v$ = useVuelidate(rules, { maxAssignmentLimit });

const assignmentHeader = computed(() =>
  hasAssignmentV2.value
    ? t('INBOX_MGMT.ASSIGNMENT.ENABLE_AUTO_ASSIGNMENT')
    : t('INBOX_MGMT.SETTINGS_POPUP.AUTO_ASSIGNMENT')
);

const assignmentDescription = computed(() =>
  hasAssignmentV2.value
    ? t('INBOX_MGMT.ASSIGNMENT.DESCRIPTION')
    : t('INBOX_MGMT.SETTINGS_POPUP.AUTO_ASSIGNMENT_SUB_TEXT')
);

const maxAssignmentLimitErrors = computed(() => {
  if (v$.value.maxAssignmentLimit.$error) {
    return t('INBOX_MGMT.AUTO_ASSIGNMENT.MAX_ASSIGNMENT_LIMIT_RANGE_ERROR');
  }
  return '';
});

const fetchAttachedAgents = async () => {
  try {
    const response = await store.dispatch('inboxMembers/get', {
      inboxId: props.inbox.id,
    });
    const {
      data: { payload: inboxMembers },
    } = response;
    selectedAgentIds.value = inboxMembers.map(m => m.id);
  } catch (error) {
    //  Handle error
  }
};

const navigateToWorkspaceConversationSettings = () => {
  const accountId = route.params.accountId;
  router.push({
    name: 'workspace_conversation_settings_index',
    params: { accountId },
  });
};

const handleToggleAutoAssignment = async val => {
  enableAutoAssignment.value = val;
  try {
    const payload = {
      id: props.inbox.id,
      formData: false,
      enable_auto_assignment: val,
    };
    await store.dispatch('inboxes/updateInbox', payload);
    useAlert(t('INBOX_MGMT.EDIT.API.SUCCESS_MESSAGE'));
  } catch (error) {
    useAlert(t('INBOX_MGMT.EDIT.API.ERROR_MESSAGE'));
  }
};

const updateAgents = async () => {
  isAgentListUpdating.value = true;
  try {
    await store.dispatch('inboxMembers/create', {
      inboxId: props.inbox.id,
      agentList: selectedAgentIds.value,
    });
    useAlert(t('AGENT_MGMT.EDIT.API.SUCCESS_MESSAGE'));
  } catch (error) {
    useAlert(t('AGENT_MGMT.EDIT.API.ERROR_MESSAGE'));
  }
  isAgentListUpdating.value = false;
};

const updateInbox = async () => {
  try {
    const payload = {
      id: props.inbox.id,
      formData: false,
      enable_auto_assignment: enableAutoAssignment.value,
      auto_assignment_config: {
        max_assignment_limit: maxAssignmentLimit.value,
      },
    };
    await store.dispatch('inboxes/updateInbox', payload);
    useAlert(t('INBOX_MGMT.EDIT.API.SUCCESS_MESSAGE'));
  } catch (error) {
    useAlert(t('INBOX_MGMT.EDIT.API.ERROR_MESSAGE'));
  }
};

const navigateToBilling = () => {
  const accountId = route.params.accountId;
  router.push({
    name: 'billing_settings_index',
    params: { accountId },
  });
};

const setDefaults = () => {
  enableAutoAssignment.value = props.inbox.enable_auto_assignment;
  maxAssignmentLimit.value =
    props.inbox.auto_assignment_config?.max_assignment_limit || null;
  fetchAttachedAgents();
};

// Watch only inbox.id to avoid unnecessary refetches when other properties change
watch(() => props.inbox.id, setDefaults);

onMounted(() => {
  setDefaults();
});
</script>

<template>
  <div>
    <SettingsFieldSection
      :label="$t('INBOX_MGMT.SETTINGS_POPUP.INBOX_AGENTS')"
      :help-text="$t('INBOX_MGMT.SETTINGS_POPUP.INBOX_AGENTS_SUB_TEXT')"
      class="[&>div]:!items-start"
    >
      <div
        class="rounded-xl outline outline-1 -outline-offset-1 outline-n-weak hover:outline-n-strong px-2 py-2"
      >
        <TagInput
          :model-value="selectedAgentNames"
          :placeholder="$t('INBOX_MGMT.ADD.AGENTS.PICK_AGENTS')"
          :menu-items="agentMenuItems"
          show-dropdown
          skip-label-dedup
          :auto-open-dropdown="false"
          @add="handleAgentAdd"
          @remove="handleAgentRemove"
        />
      </div>

      <template #extra>
        <div class="grid grid-cols-1 lg:grid-cols-8">
          <div class="col-span-1 lg:col-span-2" />
          <div class="col-span-1 lg:col-span-6 mt-4 justify-self-end">
            <NextButton
              :label="$t('INBOX_MGMT.SETTINGS_POPUP.UPDATE')"
              :is-loading="isAgentListUpdating"
              @click="updateAgents"
            />
          </div>
        </div>
      </template>
    </SettingsFieldSection>
    <SettingsAccordion
      :title="$t('INBOX_MGMT.SETTINGS_POPUP.AGENT_ASSIGNMENT')"
      class="mt-6"
    >
      <SettingsToggleSection
        v-model="enableAutoAssignment"
        compact
        :header="assignmentHeader"
        :description="assignmentDescription"
        @update:model-value="handleToggleAutoAssignment"
      >
        <template
          v-if="enableAutoAssignment && (isEnterprise || hasAssignmentV2)"
          #editor
        >
          <!-- The policy is managed for the workspace; this switch remains an explicit per-inbox on/off control. -->
          <template v-if="hasAssignmentV2">
            <div class="p-4 flex flex-col items-start gap-3">
              <p class="m-0 text-body-main text-n-slate-11">
                {{ $t('INBOX_MGMT.ASSIGNMENT.WORKSPACE_POLICY_NOTICE') }}
              </p>
              <NextButton
                :label="$t('INBOX_MGMT.ASSIGNMENT.OPEN_WORKSPACE_SETTINGS')"
                icon="i-lucide-arrow-right"
                trailing-icon
                link
                @click="navigateToWorkspaceConversationSettings"
              />
              <div v-if="!hasAdvancedAssignment" class="pt-3">
                <p class="text-body-main text-n-slate-11 mb-1">
                  {{ $t('INBOX_MGMT.ASSIGNMENT.UPGRADE_PROMPT') }}
                </p>
                <NextButton
                  :label="$t('INBOX_MGMT.ASSIGNMENT.UPGRADE_TO_BUSINESS')"
                  icon="i-lucide-arrow-right"
                  trailing-icon
                  link
                  @click="navigateToBilling"
                />
              </div>
            </div>
          </template>
          <!-- Old UI for non-assignment_v2 -->
          <template v-else-if="isEnterprise">
            <div class="p-4">
              <woot-input
                v-model="maxAssignmentLimit"
                type="number"
                :class="{ error: v$.maxAssignmentLimit.$error }"
                :error="maxAssignmentLimitErrors"
                :label="$t('INBOX_MGMT.AUTO_ASSIGNMENT.MAX_ASSIGNMENT_LIMIT')"
                class="[&>input]:!mb-0"
                @blur="v$.maxAssignmentLimit.$touch"
              />

              <p class="mt-1.5 text-label-small text-n-slate-11">
                {{
                  $t('INBOX_MGMT.AUTO_ASSIGNMENT.MAX_ASSIGNMENT_LIMIT_SUB_TEXT')
                }}
              </p>

              <div class="flex justify-end mt-4">
                <NextButton
                  :label="$t('INBOX_MGMT.SETTINGS_POPUP.UPDATE')"
                  :disabled="v$.maxAssignmentLimit.$invalid"
                  @click="updateInbox"
                />
              </div>
            </div>
          </template>
        </template>
      </SettingsToggleSection>
    </SettingsAccordion>


  </div>
</template>
