<script setup>
import { ref, watch } from 'vue';
import { useI18n } from 'vue-i18n';
import { useMapGetter } from 'dashboard/composables/store';
import { useAlert } from 'dashboard/composables';
import { useAccount } from 'dashboard/composables/useAccount';
import BaseSettingsHeader from '../components/BaseSettingsHeader.vue';
import NextButton from 'dashboard/components-next/button/Button.vue';
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
  <div class="flex flex-col w-full max-w-3xl ltr:mr-auto rtl:ml-auto">
    <BaseSettingsHeader
      :title="$t('GENERAL_SETTINGS.FORM.SCHEDULING.PAGE.TITLE')"
      :description="$t('GENERAL_SETTINGS.FORM.SCHEDULING.PAGE.NOTE')"
    />
    <section class="mt-4 min-w-0">
      <form
        v-if="!uiFlags.isFetchingItem"
        class="grid gap-4"
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

        <div>
          <NextButton blue :is-loading="uiFlags.isUpdating" type="submit">
            {{ $t('GENERAL_SETTINGS.SUBMIT') }}
          </NextButton>
        </div>
      </form>

      <woot-loading-state v-if="uiFlags.isFetchingItem" />
    </section>
  </div>
</template>
