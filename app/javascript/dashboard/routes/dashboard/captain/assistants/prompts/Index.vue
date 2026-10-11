<script setup>
import { computed, ref, watch } from 'vue';
import { useRoute } from 'vue-router';
import { useI18n } from 'vue-i18n';
import { useAlert } from 'dashboard/composables';
import { useStore } from 'dashboard/composables/store';
import { useMapGetter } from 'dashboard/composables/store';

import PageLayout from 'dashboard/components-next/captain/PageLayout.vue';
import AssistantBasicSettingsForm from 'dashboard/components-next/captain/pageComponents/assistant/settings/AssistantBasicSettingsForm.vue';
import PromptInspector from 'dashboard/components-next/captain/pageComponents/assistant/PromptInspector.vue';

const { t } = useI18n();
const route = useRoute();
const store = useStore();

const promptDescriptionFormRef = ref(null);
const PROMPT_INSTRUCTION_INITIAL_HEIGHT = 420;
const uiFlags = useMapGetter('captainAssistants/getUIFlags');
const isFetching = computed(() => uiFlags.value.fetchingItem);
const assistantId = computed(() => Number(route.params.assistantId));
const assistant = computed(() =>
  store.getters['captainAssistants/getRecord'](assistantId.value)
);
const promptInstructionMaxLength = computed(() =>
  Math.max(20_000, assistant.value?.description?.length || 0)
);

watch(
  assistantId,
  currentAssistantId => {
    if (!currentAssistantId) {
      return;
    }

    if (!store.getters['captainAssistants/getRecord'](currentAssistantId)?.id) {
      store.dispatch('captainAssistants/show', currentAssistantId);
    }
  },
  { immediate: true }
);

const handleSubmit = async updatedAssistant => {
  try {
    await store.dispatch('captainAssistants/update', {
      id: assistantId.value,
      ...(updatedAssistant?.assistant || updatedAssistant),
    });
    useAlert(t('CAPTAIN.ASSISTANTS.EDIT.SUCCESS_MESSAGE'));
  } catch (error) {
    const errorMessage =
      error?.message || t('CAPTAIN.ASSISTANTS.EDIT.ERROR_MESSAGE');
    useAlert(errorMessage);
  }
};

const handlePromptsSave = async () => {
  try {
    const payload = await promptDescriptionFormRef.value?.buildPayload?.();
    if (payload) await handleSubmit(payload);
  } catch (error) {
    useAlert(error?.message || t('CAPTAIN.ASSISTANTS.EDIT.ERROR_MESSAGE'));
  }
};
</script>

<template>
  <PageLayout
    :header-title="t('CAPTAIN.ASSISTANTS.SETTINGS.TABS.PROMPTS.LABEL')"
    :is-fetching="isFetching && !assistant?.id"
    :show-pagination-footer="false"
    :show-know-more="false"
    :button-label="t('CAPTAIN.ASSISTANTS.FORM.SAVE')"
    button-icon=""
    @click="handlePromptsSave"
  >
    <template #body>
      <div class="flex flex-col gap-6">
        <div
          class="grid gap-6 lg:grid-cols-[minmax(0,1.02fr)_minmax(24rem,1fr)]"
        >
          <div class="flex h-full flex-col gap-6">
            <div class="instructions-card flex h-full flex-col gap-6">
              <AssistantBasicSettingsForm
                ref="promptDescriptionFormRef"
                :assistant="assistant"
                :show-avatar-section="false"
                :show-name-field="false"
                :show-feature-flags="false"
                :show-submit-button="false"
                :description-max-length="promptInstructionMaxLength"
                :description-initial-height="PROMPT_INSTRUCTION_INITIAL_HEIGHT"
                description-min-height="26rem"
              />
            </div>
          </div>

          <div class="lg:self-start">
            <PromptInspector
              :assistant-id="assistant?.id"
              :assistant="assistant"
              :show-scenarios-section="false"
            />
          </div>
        </div>
      </div>
    </template>
  </PageLayout>
</template>

<style lang="scss" scoped>
.instructions-card {
  :deep(form) {
    flex: 1 1 auto;
  }

  :deep(.editor-wrapper .ProseMirror.ProseMirror-woot-style) {
    min-height: 26rem;
  }
}
</style>
