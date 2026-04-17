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
import DeleteDialog from 'dashboard/components-next/captain/pageComponents/DeleteDialog.vue';

const { t } = useI18n();
const route = useRoute();
const router = useRouter();
const store = useStore();

const deleteAssistantDialog = ref(null);
const generalBasicFormRef = ref(null);
const generalSystemFormRef = ref(null);
const draftUsageMode = ref('external_agent');

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

const mergeAssistantPayloads = (...payloads) =>
  payloads.filter(Boolean).reduce(
    (result, payload) => {
      const nextAssistant = payload.assistant || {};
      const nextConfig = nextAssistant.config || {};
      const currentAssistant = result.assistant || {};

      result.assistant = {
        ...currentAssistant,
        ...nextAssistant,
        config: {
          ...(currentAssistant.config || {}),
          ...nextConfig,
        },
      };

      if (payload.avatar !== undefined && payload.avatar !== null) {
        result.avatar = payload.avatar;
      }

      if (payload.removeAvatar) {
        result.removeAvatar = true;
      }

      return result;
    },
    {
      assistant: {
        config: {},
      },
      avatar: null,
      removeAvatar: false,
    }
  );

const handleGeneralSave = async () => {
  const basicPayload = await generalBasicFormRef.value?.buildPayload?.();
  if (!basicPayload) return;

  const systemPayload = await generalSystemFormRef.value?.buildPayload?.();
  if (!systemPayload) return;

  await handleSubmit(mergeAssistantPayloads(basicPayload, systemPayload));
};

const handleDelete = () => {
  deleteAssistantDialog.value.dialogRef.open();
};

const handleUsageModeUpdate = nextUsageMode => {
  draftUsageMode.value = nextUsageMode || 'external_agent';
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
    :header-title="t('CAPTAIN.ASSISTANTS.SETTINGS.TABS.GENERAL.LABEL')"
    :is-fetching="isFetching"
    :show-pagination-footer="false"
    :show-know-more="false"
  >
    <template #body>
      <div class="flex max-w-4xl flex-col gap-6">
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
