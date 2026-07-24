<script setup>
import { computed, ref, watch } from 'vue';
import { useRoute, useRouter } from 'vue-router';
import { useI18n } from 'vue-i18n';
import { useAlert } from 'dashboard/composables';
import { useStore } from 'dashboard/composables/store';
import { useMapGetter } from 'dashboard/composables/store';
import CaptainAssistantAPI from 'dashboard/api/captain/assistant';
import Button from 'dashboard/components-next/button/Button.vue';
import PageLayout from 'dashboard/components-next/captain/PageLayout.vue';
import SettingsHeader from 'dashboard/components-next/captain/pageComponents/settings/SettingsHeader.vue';
import AssistantBasicSettingsForm from 'dashboard/components-next/captain/pageComponents/assistant/settings/AssistantBasicSettingsForm.vue';
import AssistantSystemSettingsForm from 'dashboard/components-next/captain/pageComponents/assistant/settings/AssistantSystemSettingsForm.vue';
import VoiceAgentPreview from 'dashboard/components-next/captain/pageComponents/assistant/settings/VoiceAgentPreview.vue';
import DeleteDialog from 'dashboard/components-next/captain/pageComponents/DeleteDialog.vue';
import TabBar from 'dashboard/components-next/tabbar/TabBar.vue';

const { t } = useI18n();
const route = useRoute();
const router = useRouter();
const store = useStore();

const deleteAssistantDialog = ref(null);
const generalBasicFormRef = ref(null);
const generalSystemFormRef = ref(null);
const voiceSystemFormRef = ref(null);
const draftUsageMode = ref('external_agent');
const activeSettingsTab = ref('profile');

const uiFlags = useMapGetter('captainAssistants/getUIFlags');
const assistants = useMapGetter('captainAssistants/getRecords');
const isFetching = computed(() => uiFlags.value.fetchingItem);
const assistantId = computed(() => Number(route.params.assistantId));
const assistant = computed(() =>
  store.getters['captainAssistants/getRecord'](assistantId.value)
);
const effectiveUsageMode = computed(
  () => draftUsageMode.value || assistant.value?.usage_mode || 'external_agent'
);
const isInternalAssistant = computed(
  () => effectiveUsageMode.value === 'internal_assistant'
);
const isExternalAgent = computed(() => !isInternalAssistant.value);
const assistantConfig = computed(() => assistant.value?.config || {});
const settingsTabs = computed(() => [
  {
    key: 'profile',
    label: t('CAPTAIN.ASSISTANTS.SETTINGS.TABS.GENERAL.LABEL'),
  },
  {
    key: 'voice_agent',
    label: t('CAPTAIN.ASSISTANTS.SETTINGS.TABS.VOICE_AGENT.LABEL'),
  },
]);
const activeSettingsTabIndex = computed(() =>
  Math.max(
    settingsTabs.value.findIndex(tab => tab.key === activeSettingsTab.value),
    0
  )
);

const BASIC_SETTINGS_CONFIG_KEYS = Object.freeze([
  'feature_faq',
  'feature_memory',
  'feature_citation',
  'feature_web',
  'context_access',
  'tool_access',
]);

const SYSTEM_SETTINGS_CONFIG_KEYS = Object.freeze([
  'handoff_message',
  'resolution_message',
  'temperature',
  'auto_reply_on_last_incoming',
  'message_collapse_window_seconds',
  'history_message_limit',
]);

const VOICE_SETTINGS_CONFIG_KEYS = Object.freeze(['voice_settings']);

watch(
  assistantId,
  currentAssistantId => {
    if (!currentAssistantId) {
      return;
    }

    store.dispatch('captainAssistants/show', currentAssistantId);
  },
  { immediate: true }
);

watch(
  assistant,
  currentAssistant => {
    draftUsageMode.value = currentAssistant?.usage_mode || 'external_agent';
  },
  { immediate: true }
);

const syncAvatar = async ({ avatar, removeAvatar }) => {
  if (removeAvatar) {
    try {
      await CaptainAssistantAPI.deleteAvatar(assistantId.value);
      await store.dispatch('captainAssistants/show', assistantId.value);
      return { ok: true };
    } catch {
      return { ok: false, reason: 'delete' };
    }
  }

  if (avatar) {
    try {
      await CaptainAssistantAPI.updateAvatar(assistantId.value, avatar);
      await store.dispatch('captainAssistants/show', assistantId.value);
      return { ok: true };
    } catch {
      return { ok: false, reason: 'upload' };
    }
  }

  return { ok: true };
};

const handleSubmit = async updatedAssistant => {
  try {
    const assistantPayload = updatedAssistant?.assistant || updatedAssistant;
    const avatar = updatedAssistant?.avatar;
    const removeAvatar = updatedAssistant?.removeAvatar || false;

    await store.dispatch('captainAssistants/update', {
      id: assistantId.value,
      ...assistantPayload,
    });

    const avatarSyncResult = await syncAvatar({ avatar, removeAvatar });

    if (!avatarSyncResult.ok) {
      const avatarErrorMessage =
        avatarSyncResult.reason === 'delete'
          ? t('CAPTAIN.ASSISTANTS.AVATAR.EDIT_DELETE_ERROR')
          : t('CAPTAIN.ASSISTANTS.AVATAR.EDIT_UPLOAD_ERROR');
      useAlert(avatarErrorMessage);
      return;
    }

    useAlert(t('CAPTAIN.ASSISTANTS.EDIT.SUCCESS_MESSAGE'));
  } catch (error) {
    const errorMessage =
      error?.message || t('CAPTAIN.ASSISTANTS.EDIT.ERROR_MESSAGE');
    useAlert(errorMessage);
  }
};

const pickConfigKeys = (config = {}, keys = []) =>
  keys.reduce((result, key) => {
    if (Object.prototype.hasOwnProperty.call(config, key)) {
      result[key] = config[key];
    }

    return result;
  }, {});

const mergeAssistantPayloads = (basicPayload, systemPayload) => {
  const basicAssistant = basicPayload?.assistant || {};
  const systemAssistant = systemPayload?.assistant || {};

  return {
    assistant: {
      ...basicAssistant,
      ...systemAssistant,
      name: basicAssistant.name,
      description: basicAssistant.description,
      usage_mode: basicAssistant.usage_mode,
      config: {
        ...assistantConfig.value,
        ...pickConfigKeys(basicAssistant.config, BASIC_SETTINGS_CONFIG_KEYS),
        ...pickConfigKeys(systemAssistant.config, SYSTEM_SETTINGS_CONFIG_KEYS),
      },
    },
    avatar: basicPayload?.avatar ?? null,
    removeAvatar: Boolean(basicPayload?.removeAvatar),
  };
};

const handleGeneralSave = async () => {
  const basicPayload = await generalBasicFormRef.value?.buildPayload?.();
  if (!basicPayload) return;

  const systemPayload = await generalSystemFormRef.value?.buildPayload?.();
  if (!systemPayload) return;

  await handleSubmit(mergeAssistantPayloads(basicPayload, systemPayload));
};

const handleVoiceSave = async () => {
  const voicePayload = await voiceSystemFormRef.value?.buildPayload?.();
  if (!voicePayload) return;

  await handleSubmit({
    assistant: {
      config: {
        ...assistantConfig.value,
        ...pickConfigKeys(
          voicePayload.assistant?.config,
          VOICE_SETTINGS_CONFIG_KEYS
        ),
      },
    },
  });
};

const handleDelete = () => {
  deleteAssistantDialog.value.dialogRef.open();
};

const handleUsageModeUpdate = nextUsageMode => {
  draftUsageMode.value = nextUsageMode || 'external_agent';
};

const handleSettingsTabChanged = tab => {
  activeSettingsTab.value = tab?.key || 'profile';
};

const handleDeleteSuccess = () => {
  const remainingAssistants = assistants.value.filter(
    a => a.id !== assistantId.value
  );

  if (remainingAssistants.length > 0) {
    const nextAssistant = remainingAssistants[0];
    router.push({
      name: 'captain_assistants_settings_index',
      params: {
        accountId: route.params.accountId,
        assistantId: nextAssistant.id,
      },
    });
  } else {
    router.push({
      name: 'captain_assistants_create_index',
      params: { accountId: route.params.accountId },
    });
  }
};
</script>

<template>
  <PageLayout
    :header-title="t('CAPTAIN.ASSISTANTS.SETTINGS.HEADER')"
    :is-fetching="isFetching"
    :show-pagination-footer="false"
    :show-know-more="false"
  >
    <template #body>
      <div class="flex max-w-4xl flex-col gap-6">
        <TabBar
          active-text-class="text-n-slate-12 scale-100"
          :tabs="settingsTabs"
          :initial-active-tab="activeSettingsTabIndex"
          @tab-changed="handleSettingsTabChanged"
        />

        <template v-if="activeSettingsTab === 'profile'">
          <div class="rounded-2xl bg-n-solid-1 p-5 md:p-6">
            <div class="flex flex-col gap-6">
              <AssistantBasicSettingsForm
                ref="generalBasicFormRef"
                :assistant="assistant"
                :show-description-field="false"
                :show-submit-button="false"
                @update:usage-mode="handleUsageModeUpdate"
              />
            </div>
          </div>

          <div class="rounded-2xl bg-n-solid-1 p-5 md:p-6">
            <div class="flex flex-col gap-6">
              <SettingsHeader
                :heading="t('CAPTAIN.ASSISTANTS.SETTINGS.TABS.RUNTIME.LABEL')"
                :description="
                  t('CAPTAIN.ASSISTANTS.SETTINGS.TABS.RUNTIME.DESCRIPTION')
                "
              />
              <AssistantSystemSettingsForm
                ref="generalSystemFormRef"
                :assistant="assistant"
                :show-conversation-messages="isExternalAgent"
                :show-automation-settings="isExternalAgent"
                :show-voice-settings="false"
                :show-submit-button="false"
              />
            </div>
          </div>

          <div class="flex justify-end">
            <Button
              :label="t('CAPTAIN.ASSISTANTS.FORM.UPDATE')"
              @click="handleGeneralSave"
            />
          </div>
        </template>

        <template v-else-if="activeSettingsTab === 'voice_agent'">
          <div class="rounded-2xl bg-n-solid-1 p-5 md:p-6">
            <div class="flex flex-col gap-6">
              <SettingsHeader
                :heading="
                  t('CAPTAIN.ASSISTANTS.SETTINGS.TABS.VOICE_AGENT.LABEL')
                "
                :description="
                  t('CAPTAIN.ASSISTANTS.SETTINGS.TABS.VOICE_AGENT.DESCRIPTION')
                "
              />
              <VoiceAgentPreview
                v-if="assistant?.id"
                :assistant-id="assistant.id"
                :configured-provider="
                  assistant.config?.voice_settings?.provider || 'gemini-live'
                "
              />
              <AssistantSystemSettingsForm
                ref="voiceSystemFormRef"
                :assistant="assistant"
                :show-conversation-messages="false"
                :show-temperature-setting="false"
                :show-automation-settings="false"
                show-voice-settings
                :show-submit-button="false"
              />
            </div>
          </div>

          <div class="flex justify-end">
            <Button
              :label="t('CAPTAIN.ASSISTANTS.FORM.UPDATE')"
              @click="handleVoiceSave"
            />
          </div>
        </template>

        <div class="rounded-2xl border border-n-weak bg-n-solid-1 p-5 md:p-6">
          <SettingsHeader
            :heading="t('CAPTAIN.ASSISTANTS.SETTINGS.DELETE.TITLE')"
            :description="t('CAPTAIN.ASSISTANTS.SETTINGS.DELETE.DESCRIPTION')"
          />
          <div class="mt-6 flex justify-end">
            <div class="flex-shrink-0">
              <Button
                :label="
                  t('CAPTAIN.ASSISTANTS.SETTINGS.DELETE.BUTTON_TEXT', {
                    assistantName: assistant?.name,
                  })
                "
                color="ruby"
                class="max-w-56 !w-fit"
                @click="handleDelete"
              />
            </div>
          </div>
        </div>
      </div>
    </template>

    <DeleteDialog
      v-if="assistant"
      ref="deleteAssistantDialog"
      :entity="assistant"
      type="Assistants"
      translation-key="ASSISTANTS"
      @delete-success="handleDeleteSuccess"
    />
  </PageLayout>
</template>
