<script setup>
import { computed, ref, watch } from 'vue';
import { useRoute } from 'vue-router';
import { useI18n } from 'vue-i18n';
import { useAlert } from 'dashboard/composables';
import { useStore } from 'dashboard/composables/store';
import { useMapGetter } from 'dashboard/composables/store';

import PageLayout from 'dashboard/components-next/captain/PageLayout.vue';
import SettingsHeader from 'dashboard/components-next/captain/pageComponents/settings/SettingsHeader.vue';
import AssistantBasicSettingsForm from 'dashboard/components-next/captain/pageComponents/assistant/settings/AssistantBasicSettingsForm.vue';
import AssistantRulesManager from 'dashboard/components-next/captain/pageComponents/assistant/settings/AssistantRulesManager.vue';
import AssistantScenariosManager from 'dashboard/components-next/captain/pageComponents/assistant/settings/AssistantScenariosManager.vue';
import PromptInspector from 'dashboard/components-next/captain/pageComponents/assistant/PromptInspector.vue';
import TabBar from 'dashboard/components-next/tabbar/TabBar.vue';

const { t } = useI18n();
const route = useRoute();
const store = useStore();

const promptDescriptionFormRef = ref(null);
const promptRulesManagerRef = ref(null);
const PROMPT_INSTRUCTION_MAX_LENGTH = 20_000;
const uiFlags = useMapGetter('captainAssistants/getUIFlags');
const isFetching = computed(() => uiFlags.value.fetchingItem);
const assistantId = computed(() => Number(route.params.assistantId));
const assistant = computed(() =>
  store.getters['captainAssistants/getRecord'](assistantId.value)
);
const isInternalAssistant = computed(
  () => assistant.value?.usage_mode === 'internal_assistant'
);
const isExternalAgent = computed(() => !isInternalAssistant.value);
const promptTabs = computed(() => [
  {
    key: 'rules',
    label: t('CAPTAIN.ASSISTANTS.SETTINGS.TABS.PROMPT_TABS.RULES'),
  },
  {
    key: 'scenarios',
    label: t('CAPTAIN.ASSISTANTS.SETTINGS.TABS.PROMPT_TABS.SCENARIOS'),
  },
]);
const activePromptTab = ref(promptTabs.value[0]?.key || 'rules');

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

      return result;
    },
    {
      assistant: {
        config: {},
      },
    }
  );

const handlePromptsSave = async () => {
  try {
    const instructionPayload =
      await promptDescriptionFormRef.value?.buildPayload?.();
    const rulesPayload =
      activePromptTab.value === 'rules'
        ? await promptRulesManagerRef.value?.buildPayload?.()
        : null;
    const mergedPayload = mergeAssistantPayloads(
      instructionPayload,
      rulesPayload
    );

    if (!instructionPayload && !rulesPayload) {
      return;
    }

    await handleSubmit(mergedPayload);
  } catch (error) {
    useAlert(error?.message || t('CAPTAIN.ASSISTANTS.EDIT.ERROR_MESSAGE'));
  }
};

const onPromptTabChanged = tab => {
  activePromptTab.value = tab?.key || 'rules';
};
</script>

<template>
  <PageLayout
    :header-title="t('CAPTAIN.ASSISTANTS.SETTINGS.TABS.PROMPTS.LABEL')"
    :is-fetching="isFetching"
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
            <div
              class="instructions-card rounded-2xl bg-n-solid-1 p-5 md:p-6 flex h-full flex-col gap-6"
            >
              <SettingsHeader
                :heading="t('CAPTAIN.ASSISTANTS.SETTINGS.TABS.PROMPTS.LABEL')"
                :description="
                  t('CAPTAIN.ASSISTANTS.SETTINGS.INSTRUCTIONS.DESCRIPTION')
                "
              />
              <AssistantBasicSettingsForm
                ref="promptDescriptionFormRef"
                :assistant="assistant"
                :show-avatar-section="false"
                :show-name-field="false"
                :show-usage-mode-field="false"
                :show-feature-flags="false"
                :show-submit-button="false"
                :description-max-length="PROMPT_INSTRUCTION_MAX_LENGTH"
              />
            </div>
          </div>

          <div class="lg:self-start">
            <PromptInspector
              :assistant-id="assistant?.id"
              :assistant="assistant"
              :show-assistant-section="isExternalAgent"
              :show-copilot-section="isInternalAssistant"
              :show-scenarios-section="false"
            />
          </div>
        </div>

        <div v-if="isExternalAgent" class="flex flex-col gap-6 pt-2">
          <div class="border-t border-n-weak" />
          <div class="rounded-2xl bg-n-solid-1 p-5 md:p-6 flex flex-col gap-5">
            <div class="flex items-center justify-start">
              <TabBar
                :tabs="promptTabs"
                :initial-active-tab="
                  promptTabs.findIndex(tab => tab.key === activePromptTab)
                "
                @tab-changed="onPromptTabChanged"
              />
            </div>

            <AssistantRulesManager
              v-if="activePromptTab === 'rules'"
              ref="promptRulesManagerRef"
              :assistant-id="assistantId"
              :assistant="assistant"
              :show-header="false"
            />
            <AssistantScenariosManager
              v-else
              :assistant-id="assistantId"
              :show-header="false"
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
    min-height: 19rem;
  }
}
</style>
