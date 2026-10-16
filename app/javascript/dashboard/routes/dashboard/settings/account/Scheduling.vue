<script setup>
import { computed, ref, watch } from 'vue';
import { useI18n } from 'vue-i18n';
import { useMapGetter } from 'dashboard/composables/store';
import { useAlert } from 'dashboard/composables';
import { useAccount } from 'dashboard/composables/useAccount';
import { usePolicy } from 'dashboard/composables/usePolicy';
import { FEATURE_FLAGS } from 'dashboard/featureFlags';
import { useCrmReferencesStore } from 'dashboard/stores/crm/references';
import IntegrationsAPI from 'dashboard/api/integrations';
import CrmAppointmentAutomationSettings from 'dashboard/components-next/CRM/CrmAppointmentAutomationSettings.vue';
import { appointmentAutomationDraft } from 'dashboard/components-next/CRM/appointmentAutomation';
import BaseSettingsHeader from '../components/BaseSettingsHeader.vue';
import NextButton from 'dashboard/components-next/button/Button.vue';
import Switch from 'dashboard/components-next/switch/Switch.vue';

const { t } = useI18n();
const { currentAccount, updateAccount } = useAccount();
const { checkPermissions } = usePolicy();
const referencesStore = useCrmReferencesStore();
const uiFlags = useMapGetter('accounts/getUIFlags');
const accountId = useMapGetter('getCurrentAccountId');
const isFeatureEnabledonAccount = useMapGetter(
  'accounts/isFeatureEnabledonAccount'
);

const schedulingCompanyEnabled = ref(true);
const schedulingContactRequired = ref(true);
const selectedPipelineId = ref('');
const appointmentAutomationState = ref(appointmentAutomationDraft());
const appointmentSettingsRef = ref(null);
const medelementInstalled = ref(false);
const isSavingAppointmentAutomation = ref(false);

const dealsEnabled = computed(
  () =>
    Boolean(accountId.value) &&
    isFeatureEnabledonAccount.value(accountId.value, FEATURE_FLAGS.CRM_DEALS)
);
const canManageCrm = computed(() =>
  checkPermissions(['administrator', 'crm_settings_manage'])
);
const activePipelines = computed(() =>
  [...referencesStore.pipelines]
    .filter(pipeline => pipeline.active !== false)
    .sort(
      (left, right) =>
        Number(left.position ?? 0) - Number(right.position ?? 0) ||
        Number(left.id) - Number(right.id)
    )
);

const hasActiveAppointmentAutomation = pipeline => {
  const config =
    pipeline?.appointmentAutomation || pipeline?.appointment_automation || {};
  return Boolean(
    config.auto_create_deals || config.autoCreateDeals || config.enabled
  );
};

const preferredPipeline = computed(
  () =>
    activePipelines.value.find(hasActiveAppointmentAutomation) ||
    activePipelines.value.find(pipeline => pipeline.default) ||
    activePipelines.value[0] ||
    null
);

const selectedPipeline = computed(
  () =>
    activePipelines.value.find(
      pipeline => String(pipeline.id) === String(selectedPipelineId.value)
    ) ||
    preferredPipeline.value ||
    null
);

const syncFromAccount = () => {
  const accountSettings = currentAccount.value?.settings || {};

  schedulingContactRequired.value =
    accountSettings.scheduling_contact_required !== false;
  schedulingCompanyEnabled.value =
    accountSettings.scheduling_company_enabled !== false;
};

const syncAppointmentAutomationFromPipeline = pipeline => {
  if (!pipeline) {
    appointmentAutomationState.value = appointmentAutomationDraft();
    return;
  }
  selectedPipelineId.value = String(pipeline.id);
  appointmentAutomationState.value = appointmentAutomationDraft(
    pipeline.appointmentAutomation || pipeline.appointment_automation
  );
};

const selectPipeline = pipelineId => {
  selectedPipelineId.value = String(pipelineId || '');
  const target = activePipelines.value.find(
    pipeline => String(pipeline.id) === String(pipelineId)
  );
  syncAppointmentAutomationFromPipeline(target);
};

const loadInstalledIntegrations = async requestAccountId => {
  medelementInstalled.value = false;
  try {
    const response = await IntegrationsAPI.get();
    if (String(accountId.value) !== requestAccountId) return;
    medelementInstalled.value = (response?.data?.payload || []).some(
      integration =>
        integration.id === 'medelement' && integration.hooks?.length
    );
  } catch {
    // Integration-specific settings stay hidden if the catalog cannot be read.
  }
};

const loadCrmAutomationSettings = async () => {
  const requestAccountId = String(accountId.value || '');
  if (!requestAccountId || !dealsEnabled.value) return;
  selectedPipelineId.value = '';
  await Promise.all([
    referencesStore
      .loadPipelines({ include_inactive_stages: true })
      .catch(() => {}),
    loadInstalledIntegrations(requestAccountId),
  ]);
  if (String(accountId.value) !== requestAccountId) return;
  syncAppointmentAutomationFromPipeline(selectedPipeline.value);
};

watch(currentAccount, syncFromAccount, { deep: true, immediate: true });
watch(
  [accountId, dealsEnabled],
  () => {
    loadCrmAutomationSettings();
  },
  { immediate: true }
);
watch(selectedPipeline, pipeline => {
  if (pipeline && !selectedPipelineId.value) {
    syncAppointmentAutomationFromPipeline(pipeline);
  }
});

const saveSchedulingSettings = async () => {
  const shouldSaveAppointmentAutomation =
    dealsEnabled.value &&
    canManageCrm.value &&
    Boolean(selectedPipeline.value);
  const appointmentPayload = shouldSaveAppointmentAutomation
    ? appointmentSettingsRef.value?.buildPayload()
    : null;

  if (shouldSaveAppointmentAutomation && !appointmentPayload) {
    useAlert(t('CRM.ERRORS.VALIDATION_ERROR'));
    return;
  }

  isSavingAppointmentAutomation.value = true;
  try {
    await updateAccount({
      scheduling_contact_required: schedulingContactRequired.value,
      scheduling_company_enabled: schedulingCompanyEnabled.value,
    });
    if (shouldSaveAppointmentAutomation) {
      await referencesStore.savePipelineSettings(selectedPipeline.value.id, {
        appointment_automation: appointmentPayload,
      });
      syncAppointmentAutomationFromPipeline(selectedPipeline.value);
    }
    useAlert(t('GENERAL_SETTINGS.UPDATE.SUCCESS'));
  } catch {
    syncFromAccount();
    if (shouldSaveAppointmentAutomation) {
      syncAppointmentAutomationFromPipeline(selectedPipeline.value);
    }
    useAlert(t('GENERAL_SETTINGS.UPDATE.ERROR'));
  } finally {
    isSavingAppointmentAutomation.value = false;
  }
};
</script>

<template>
  <div class="flex flex-col w-full max-w-3xl ltr:mr-auto rtl:ml-auto">
    <BaseSettingsHeader
      :title="$t('GENERAL_SETTINGS.FORM.SCHEDULING.PAGE.TITLE')"
      :description="$t('GENERAL_SETTINGS.FORM.SCHEDULING.PAGE.NOTE')"
    />
    <section class="mt-4 min-w-0">
      <form
        v-if="!uiFlags.isFetchingItem"
        class="grid gap-6"
        @submit.prevent="saveSchedulingSettings"
      >
        <div
          class="divide-y divide-n-weak rounded-xl outline outline-1 -outline-offset-1 outline-n-weak"
        >
          <div class="flex flex-col gap-1 px-4 py-3">
            <div class="flex items-center justify-between gap-3">
              <span class="min-w-0 text-heading-3 text-n-slate-12">
                {{
                  $t('GENERAL_SETTINGS.FORM.SCHEDULING.CONTACT_REQUIRED.LABEL')
                }}
              </span>
              <Switch v-model="schedulingContactRequired" />
            </div>
            <p class="mb-0 text-body-main text-n-slate-11">
              {{ $t('GENERAL_SETTINGS.FORM.SCHEDULING.CONTACT_REQUIRED.NOTE') }}
            </p>
          </div>

          <div class="flex flex-col gap-1 px-4 py-3">
            <div class="flex items-center justify-between gap-3">
              <span class="min-w-0 text-heading-3 text-n-slate-12">
                {{
                  $t('GENERAL_SETTINGS.FORM.SCHEDULING.COMPANY_ENABLED.LABEL')
                }}
              </span>
              <Switch v-model="schedulingCompanyEnabled" />
            </div>
            <p class="mb-0 text-body-main text-n-slate-11">
              {{ $t('GENERAL_SETTINGS.FORM.SCHEDULING.COMPANY_ENABLED.NOTE') }}
            </p>
          </div>
        </div>

        <CrmAppointmentAutomationSettings
          v-if="dealsEnabled && selectedPipeline"
          ref="appointmentSettingsRef"
          v-model="appointmentAutomationState"
          :pipeline="selectedPipeline"
          :pipelines="activePipelines"
          :selected-pipeline-id="selectedPipeline.id"
          :can-manage="canManageCrm"
          :saving="uiFlags.isUpdating || isSavingAppointmentAutomation"
          :medelement-installed="medelementInstalled"
          @update:selected-pipeline-id="selectPipeline"
        />

        <div>
          <NextButton
            blue
            :is-loading="uiFlags.isUpdating || isSavingAppointmentAutomation"
            type="submit"
          >
            {{ $t('GENERAL_SETTINGS.SUBMIT') }}
          </NextButton>
        </div>
      </form>

      <woot-loading-state v-if="uiFlags.isFetchingItem" />
    </section>
  </div>
</template>
