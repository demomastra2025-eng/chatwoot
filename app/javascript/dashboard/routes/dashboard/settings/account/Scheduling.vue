<script setup>
import { ref, watch } from 'vue';
import { useI18n } from 'vue-i18n';
import { useMapGetter } from 'dashboard/composables/store';
import { useAlert } from 'dashboard/composables';
import { useAccount } from 'dashboard/composables/useAccount';

import BaseSettingsHeader from '../components/BaseSettingsHeader.vue';
import NextButton from 'dashboard/components-next/button/Button.vue';

import SectionLayout from './components/SectionLayout.vue';
import Switch from 'dashboard/components-next/switch/Switch.vue';

const { t } = useI18n();
const { currentAccount, updateAccount } = useAccount();

const uiFlags = useMapGetter('accounts/getUIFlags');

const schedulingCompanyEnabled = ref(true);
const schedulingContactRequired = ref(true);

const syncFromAccount = () => {
  const accountSettings = currentAccount.value?.settings || {};

  schedulingContactRequired.value =
    accountSettings.scheduling_contact_required !== false;
  schedulingCompanyEnabled.value =
    accountSettings.scheduling_company_enabled !== false;
};

watch(currentAccount, syncFromAccount, { deep: true, immediate: true });

const saveSchedulingSettings = async () => {
  try {
    await updateAccount({
      scheduling_contact_required: schedulingContactRequired.value,
      scheduling_company_enabled: schedulingCompanyEnabled.value,
    });
    useAlert(t('GENERAL_SETTINGS.UPDATE.SUCCESS'));
  } catch {
    syncFromAccount();
    useAlert(t('GENERAL_SETTINGS.UPDATE.ERROR'));
  }
};
</script>

<template>
  <div class="flex flex-col w-full max-w-2xl ltr:mr-auto rtl:ml-auto">
    <BaseSettingsHeader
      :title="$t('GENERAL_SETTINGS.FORM.SCHEDULING.PAGE.TITLE')"
      :description="$t('GENERAL_SETTINGS.FORM.SCHEDULING.PAGE.NOTE')"
    />
    <div class="flex-grow flex-shrink min-w-0 mt-3">
      <SectionLayout
        :title="$t('GENERAL_SETTINGS.FORM.SCHEDULING.PAGE.SECTION_TITLE')"
        :description="$t('GENERAL_SETTINGS.FORM.SCHEDULING.PAGE.SECTION_NOTE')"
        class="!pt-0"
      >
        <form
          v-if="!uiFlags.isFetchingItem"
          class="grid gap-4"
          @submit.prevent="saveSchedulingSettings"
        >
          <div class="grid gap-4 rounded-xl border border-n-weak p-4">
            <div class="flex items-start justify-between gap-4">
              <div class="min-w-0">
                <p class="mb-1 text-sm font-medium text-n-slate-12">
                  {{
                    $t(
                      'GENERAL_SETTINGS.FORM.SCHEDULING.CONTACT_REQUIRED.LABEL'
                    )
                  }}
                </p>
                <p class="text-sm text-n-slate-11">
                  {{
                    $t('GENERAL_SETTINGS.FORM.SCHEDULING.CONTACT_REQUIRED.NOTE')
                  }}
                </p>
              </div>
              <Switch v-model="schedulingContactRequired" />
            </div>

            <div class="flex items-start justify-between gap-4">
              <div class="min-w-0">
                <p class="mb-1 text-sm font-medium text-n-slate-12">
                  {{
                    $t('GENERAL_SETTINGS.FORM.SCHEDULING.COMPANY_ENABLED.LABEL')
                  }}
                </p>
                <p class="text-sm text-n-slate-11">
                  {{
                    $t('GENERAL_SETTINGS.FORM.SCHEDULING.COMPANY_ENABLED.NOTE')
                  }}
                </p>
              </div>
              <Switch v-model="schedulingCompanyEnabled" />
            </div>
          </div>

          <div>
            <NextButton blue :is-loading="uiFlags.isUpdating" type="submit">
              {{ $t('GENERAL_SETTINGS.SUBMIT') }}
            </NextButton>
          </div>
        </form>

        <woot-loading-state v-if="uiFlags.isFetchingItem" />
      </SectionLayout>
    </div>
  </div>
</template>
