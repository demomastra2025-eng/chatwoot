<script setup>
import { computed, ref, watch } from 'vue';
import { useI18n } from 'vue-i18n';
import { useAlert } from 'dashboard/composables';
import { accountSettingsMatch } from 'dashboard/helper/accountSettings';
import { useStore } from 'dashboard/composables/store';
import Button from 'dashboard/components-next/button/Button.vue';
import TextArea from 'dashboard/components-next/textarea/TextArea.vue';
import SettingsToggleSection from 'dashboard/components-next/Settings/SettingsToggleSection.vue';
import SectionLayout from './SectionLayout.vue';

const props = defineProps({
  account: { type: Object, required: true },
  disabled: { type: Boolean, default: false },
});
const { t } = useI18n();
const store = useStore();
const enabled = ref(false);
const message = ref('');
const saving = ref(false);
const showValidation = ref(false);
const isDisabled = computed(
  () => props.disabled || saving.value || !props.account.id
);
const scheduleConfigured = computed(
  () => props.account.settings?.workspace_working_hours?.length === 7
);
const validationMessage = computed(() => {
  if (!showValidation.value || !enabled.value) return '';
  if (!scheduleConfigured.value)
    return t('GENERAL_SETTINGS.OUT_OF_OFFICE.SCHEDULE_HINT');
  return message.value.trim()
    ? ''
    : t('GENERAL_SETTINGS.OUT_OF_OFFICE.REQUIRED');
});
const hydrate = config => {
  enabled.value = config?.enabled === true;
  message.value = config?.message || '';
  showValidation.value = false;
};
watch(
  [
    () => props.account.id,
    () => props.account.settings?.workspace_out_of_office?.enabled,
    () => props.account.settings?.workspace_out_of_office?.message,
  ],
  ([id], previous = []) => {
    if (id !== previous[0] || !saving.value)
      hydrate(props.account.settings?.workspace_out_of_office);
  },
  { immediate: true }
);
const save = async () => {
  if (isDisabled.value) return;
  showValidation.value = true;
  if (validationMessage.value) return;
  saving.value = true;
  const accountId = props.account.id;
  try {
    const settings = {
      workspace_out_of_office: {
        enabled: enabled.value,
        message: message.value.trim(),
      },
    };
    const updated = await store.dispatch('accounts/update', {
      id: accountId,
      ...settings,
    });
    if (!accountSettingsMatch(updated, settings))
      throw new Error(t('GENERAL_SETTINGS.OUT_OF_OFFICE.ERROR'));
    if (props.account.id === accountId) {
      if (updated?.settings?.workspace_out_of_office)
        hydrate(updated.settings.workspace_out_of_office);
      useAlert(t('GENERAL_SETTINGS.OUT_OF_OFFICE.SUCCESS'));
    }
  } catch {
    if (props.account.id === accountId)
      useAlert(t('GENERAL_SETTINGS.OUT_OF_OFFICE.ERROR'));
  } finally {
    saving.value = false;
  }
};
</script>

<template>
  <SectionLayout
    :title="t('GENERAL_SETTINGS.OUT_OF_OFFICE.TITLE')"
    :description="t('GENERAL_SETTINGS.OUT_OF_OFFICE.DESCRIPTION')"
    with-border
  >
    <div class="flex flex-col gap-4">
      <p v-if="!scheduleConfigured" class="m-0 text-sm text-n-slate-11">
        {{ t('GENERAL_SETTINGS.OUT_OF_OFFICE.SCHEDULE_HINT') }}
      </p>
      <SettingsToggleSection
        v-model="enabled"
        :header="t('GENERAL_SETTINGS.OUT_OF_OFFICE.ENABLED_LABEL')"
        :disabled="isDisabled || (!scheduleConfigured && !enabled)"
      >
        <template v-if="enabled" #editor>
          <TextArea
            id="workspace-out-of-office-message"
            v-model="message"
            :label="t('GENERAL_SETTINGS.OUT_OF_OFFICE.MESSAGE_LABEL')"
            :placeholder="t('GENERAL_SETTINGS.OUT_OF_OFFICE.PLACEHOLDER')"
            :disabled="isDisabled"
            :max-length="10000"
            show-character-count
            :message="validationMessage"
            :message-type="validationMessage ? 'error' : 'info'"
          />
        </template>
      </SettingsToggleSection>
      <div v-if="!disabled" class="flex justify-end">
        <Button
          data-test="workspace-out-of-office-save"
          :label="t('GENERAL_SETTINGS.OUT_OF_OFFICE.SAVE')"
          :disabled="isDisabled"
          :is-loading="saving"
          @click="save"
        />
      </div>
    </div>
  </SectionLayout>
</template>
