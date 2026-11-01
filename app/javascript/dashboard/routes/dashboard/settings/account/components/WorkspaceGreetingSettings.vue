<script setup>
import { computed, ref, watch } from 'vue';
import { useI18n } from 'vue-i18n';
import { useAlert } from 'dashboard/composables';
import { accountSettingsMatch } from 'dashboard/helper/accountSettings';
import { useMapGetter, useStore } from 'dashboard/composables/store';
import { INBOX_TYPES } from 'dashboard/helper/inbox';
import Button from 'dashboard/components-next/button/Button.vue';
import Checkbox from 'dashboard/components-next/checkbox/Checkbox.vue';
import TextArea from 'dashboard/components-next/textarea/TextArea.vue';
import SettingsToggleSection from 'dashboard/components-next/Settings/SettingsToggleSection.vue';
import SectionLayout from './SectionLayout.vue';

const props = defineProps({
  account: { type: Object, default: () => ({}) },
  disabled: { type: Boolean, default: false },
});
const { t } = useI18n();
const store = useStore();
const inboxes = useMapGetter('inboxes/getInboxes');
const textInboxes = computed(() =>
  (inboxes.value || []).filter(
    inbox =>
      ![INBOX_TYPES.VOICE, INBOX_TYPES.EMAIL].includes(inbox.channel_type)
  )
);
const greetingEnabled = ref(false);
const greetingMessage = ref('');
const excludedInboxIds = ref([]);
const isSaving = ref(false);
const showValidation = ref(false);
const isDisabled = computed(
  () => props.disabled || isSaving.value || !props.account.id
);
const selectedInboxIds = computed({
  get: () =>
    textInboxes.value
      .filter(inbox => !excludedInboxIds.value.includes(inbox.id))
      .map(inbox => inbox.id),
  set: ids => {
    excludedInboxIds.value = textInboxes.value
      .filter(inbox => !ids.includes(inbox.id))
      .map(inbox => inbox.id);
  },
});
const validationMessage = computed(() =>
  showValidation.value && greetingEnabled.value && !greetingMessage.value.trim()
    ? t('GENERAL_SETTINGS.CONVERSATIONS.GREETING_MESSAGE_REQUIRED')
    : ''
);
const hydrate = config => {
  greetingEnabled.value = config?.enabled === true;
  greetingMessage.value = config?.message || '';
  excludedInboxIds.value = [...(config?.excluded_inbox_ids || [])];
  showValidation.value = false;
};
watch(
  [
    () => props.account.id,
    () => props.account.settings?.workspace_greeting?.enabled,
    () => props.account.settings?.workspace_greeting?.message,
    () =>
      [
        ...(props.account.settings?.workspace_greeting?.excluded_inbox_ids ||
          []),
      ]
        .sort((left, right) => left - right)
        .join(','),
  ],
  ([id], previous = []) => {
    if (id !== previous[0] || !isSaving.value)
      hydrate(props.account.settings?.workspace_greeting);
  },
  { immediate: true }
);

const saveGreetingSettings = async () => {
  if (isDisabled.value) return;
  showValidation.value = true;
  if (validationMessage.value) return;
  isSaving.value = true;
  const accountId = props.account.id;
  try {
    const settings = {
      workspace_greeting: {
        enabled: greetingEnabled.value,
        message: greetingMessage.value.trim(),
        excluded_inbox_ids: textInboxes.value
          .filter(inbox => !selectedInboxIds.value.includes(inbox.id))
          .map(inbox => inbox.id),
      },
    };
    const updated = await store.dispatch('accounts/update', {
      id: accountId,
      ...settings,
    });
    if (!accountSettingsMatch(updated, settings))
      throw new Error(
        t('GENERAL_SETTINGS.CONVERSATIONS.GREETING_UPDATE_ERROR')
      );
    if (props.account.id === accountId) {
      if (updated?.settings?.workspace_greeting)
        hydrate(updated.settings.workspace_greeting);
      useAlert(t('GENERAL_SETTINGS.CONVERSATIONS.GREETING_UPDATE_SUCCESS'));
    }
  } catch {
    if (props.account.id === accountId)
      useAlert(t('GENERAL_SETTINGS.CONVERSATIONS.GREETING_UPDATE_ERROR'));
  } finally {
    isSaving.value = false;
  }
};
</script>

<template>
  <SectionLayout
    :title="t('GENERAL_SETTINGS.CONVERSATIONS.GREETING_TITLE')"
    :description="t('GENERAL_SETTINGS.CONVERSATIONS.GREETING_DESCRIPTION')"
    with-border
  >
    <div class="flex flex-col gap-4" data-test="workspace-greeting-settings">
      <SettingsToggleSection
        v-model="greetingEnabled"
        :header="t('GENERAL_SETTINGS.CONVERSATIONS.GREETING_ENABLED_LABEL')"
        :disabled="isDisabled"
      >
        <template v-if="greetingEnabled" #editor>
          <div class="flex flex-col gap-4">
            <TextArea
              id="workspace-greeting-message"
              v-model="greetingMessage"
              :label="
                t('GENERAL_SETTINGS.CONVERSATIONS.GREETING_MESSAGE_LABEL')
              "
              :placeholder="
                t('GENERAL_SETTINGS.CONVERSATIONS.GREETING_MESSAGE_PLACEHOLDER')
              "
              :disabled="isDisabled"
              :max-length="10000"
              show-character-count
              :message="validationMessage"
              :message-type="validationMessage ? 'error' : 'info'"
            />
            <div class="flex flex-col gap-2">
              <div class="flex flex-wrap items-center justify-between gap-2">
                <span class="text-sm font-medium text-n-slate-12">{{
                  t('GENERAL_SETTINGS.CONVERSATIONS.GREETING_CHANNELS_LABEL')
                }}</span>
                <div class="flex items-center gap-2">
                  <Button
                    variant="link"
                    size="sm"
                    :disabled="isDisabled"
                    :label="
                      t('GENERAL_SETTINGS.CONVERSATIONS.SELECT_ALL_CHANNELS')
                    "
                    @click="
                      selectedInboxIds = textInboxes.map(inbox => inbox.id)
                    "
                  />
                  <Button
                    variant="link"
                    color="slate"
                    size="sm"
                    :disabled="isDisabled"
                    :label="
                      t('GENERAL_SETTINGS.CONVERSATIONS.CLEAR_ALL_CHANNELS')
                    "
                    @click="selectedInboxIds = []"
                  />
                </div>
              </div>
              <p v-if="!textInboxes.length" class="m-0 text-sm text-n-slate-11">
                {{ t('GENERAL_SETTINGS.CONVERSATIONS.NO_TEXT_CHANNELS') }}
              </p>
              <div v-else class="grid grid-cols-1 gap-2 sm:grid-cols-2">
                <label
                  v-for="inbox in textInboxes"
                  :key="inbox.id"
                  :for="`workspace-greeting-inbox-${inbox.id}`"
                  class="flex items-center gap-2 text-sm text-n-slate-12"
                >
                  <Checkbox
                    :id="`workspace-greeting-inbox-${inbox.id}`"
                    v-model="selectedInboxIds"
                    :value="inbox.id"
                    :disabled="isDisabled"
                  />
                  <span class="min-w-0 break-words">{{ inbox.name }}</span>
                </label>
              </div>
              <p class="m-0 text-xs text-n-slate-11">
                {{ t('GENERAL_SETTINGS.CONVERSATIONS.GREETING_INHERIT_HINT') }}
              </p>
              <p class="m-0 text-xs text-n-slate-11">
                {{ t('GENERAL_SETTINGS.CONVERSATIONS.GREETING_AI_SKIP_HINT') }}
              </p>
            </div>
          </div>
        </template>
      </SettingsToggleSection>
      <div v-if="!disabled" class="flex justify-end">
        <Button
          data-test="workspace-greeting-save"
          :label="t('GENERAL_SETTINGS.CONVERSATIONS.GREETING_SAVE')"
          :disabled="isDisabled"
          :is-loading="isSaving"
          @click="saveGreetingSettings"
        />
      </div>
    </div>
  </SectionLayout>
</template>
