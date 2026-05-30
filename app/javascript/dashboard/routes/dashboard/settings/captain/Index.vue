<script setup>
import { computed, onMounted, reactive, ref, watch } from 'vue';
import { useI18n } from 'vue-i18n';
import { storeToRefs } from 'pinia';
import { useAlert } from 'dashboard/composables';
import { useAccount } from 'dashboard/composables/useAccount';
import { useCaptain } from 'dashboard/composables/useCaptain';
import { useConfig } from 'dashboard/composables/useConfig';
import { useCaptainConfigStore } from 'dashboard/store/captain/preferences';

import SettingsLayout from '../SettingsLayout.vue';
import BaseSettingsHeader from '../components/BaseSettingsHeader.vue';
import SectionLayout from '../account/components/SectionLayout.vue';
import ModelSelector from './components/ModelSelector.vue';
import ModelDropdown from './components/ModelDropdown.vue';
import { shouldShowAudioTranscriptionPrompt } from './helpers/modelDiagnostics';
import NextButton from 'dashboard/components-next/button/Button.vue';
import Icon from 'dashboard/components-next/icon/Icon.vue';
import Input from 'dashboard/components-next/input/Input.vue';
import NextSelect from 'dashboard/components-next/select/Select.vue';
import Switch from 'dashboard/components-next/switch/Switch.vue';
import TextArea from 'dashboard/components-next/textarea/TextArea.vue';
import CaptainPaywall from 'next/captain/pageComponents/Paywall.vue';

const { t } = useI18n();
const { captainEnabled } = useCaptain();
const { isEnterprise, enterprisePlanName } = useConfig();
const { isOnChatwootCloud } = useAccount();

const captainConfigStore = useCaptainConfigStore();
const {
  uiFlags,
  providers,
  runtime,
  runtimeMetadata,
  providerCredentials,
  features,
} = storeToRefs(captainConfigStore);

const isLoading = computed(() => uiFlags.value.isFetching);
const audioTranscriptionPrompt = ref('');
const knowledgeChunkSize = ref(0);
const moderationFailureMode = ref('fail_open');
const runtimeThinkingEfforts = ref({
  assistant: 'none',
  copilot: 'none',
});
const providerApiKeys = reactive({});
const numberFormatter = new Intl.NumberFormat();

const modelFeatures = computed(() => [
  {
    key: 'editor',
    title: t('CAPTAIN_SETTINGS.MODEL_CONFIG.EDITOR.TITLE'),
    description: t('CAPTAIN_SETTINGS.MODEL_CONFIG.EDITOR.DESCRIPTION'),
  },
  {
    key: 'assistant',
    title: t('CAPTAIN_SETTINGS.MODEL_CONFIG.ASSISTANT.TITLE'),
    description: t('CAPTAIN_SETTINGS.MODEL_CONFIG.ASSISTANT.DESCRIPTION'),
    enterprise: true,
  },
  {
    key: 'copilot',
    title: t('CAPTAIN_SETTINGS.MODEL_CONFIG.COPILOT.TITLE'),
    description: t('CAPTAIN_SETTINGS.MODEL_CONFIG.COPILOT.DESCRIPTION'),
    enterprise: true,
  },
]);

const specializedModelFeatures = computed(() => [
  {
    key: 'moderation',
    title: t('CAPTAIN_SETTINGS.MODEL_CONFIG.MODERATION.TITLE'),
    description: t('CAPTAIN_SETTINGS.MODEL_CONFIG.MODERATION.DESCRIPTION'),
    enterprise: true,
  },
  {
    key: 'audio_transcription',
    title: t('CAPTAIN_SETTINGS.MODEL_CONFIG.AUDIO_TRANSCRIPTION.TITLE'),
    description: t(
      'CAPTAIN_SETTINGS.MODEL_CONFIG.AUDIO_TRANSCRIPTION.DESCRIPTION'
    ),
    enterprise: true,
  },
  {
    key: 'image_recognition',
    title: t('CAPTAIN_SETTINGS.MODEL_CONFIG.IMAGE_RECOGNITION.TITLE'),
    description: t(
      'CAPTAIN_SETTINGS.MODEL_CONFIG.IMAGE_RECOGNITION.DESCRIPTION'
    ),
    enterprise: true,
  },
  {
    key: 'help_center_search',
    title: t('CAPTAIN_SETTINGS.MODEL_CONFIG.EMBEDDINGS.TITLE'),
    description: t('CAPTAIN_SETTINGS.MODEL_CONFIG.EMBEDDINGS.DESCRIPTION'),
    enterprise: true,
  },
]);

const shouldShowFeature = feature => {
  // Cloud will always see these features as long as captain is enabled
  if (isOnChatwootCloud.value && captainEnabled) {
    return true;
  }

  if (feature.enterprise) {
    // if the app is in enterprise mode, then we can show the feature
    // this is not the installation plan, but when the enterprise folder is missing
    return isEnterprise;
  }

  return true;
};

const isFeatureAccessible = feature => {
  // Cloud will always see these features as long as captain is enabled
  if (isOnChatwootCloud.value && captainEnabled) {
    return true;
  }

  if (feature.enterprise) {
    // plan is shown, but is it accessible?
    // This ensures that the instance has purchased the enterprise license, and only then we allow
    // access
    return isEnterprise && enterprisePlanName === 'enterprise';
  }

  return true;
};

const storedAudioTranscriptionPrompt = computed(
  () => runtime.value.audio_transcription_prompt || ''
);
const knowledgeIndexingMetadata = computed(
  () => runtimeMetadata.value.knowledge_indexing || {}
);
const knowledgeVectorDimensions = computed(() =>
  Number(knowledgeIndexingMetadata.value.vector_dimensions || 1536)
);
const knowledgeChunkDefault = computed(() =>
  Number(
    knowledgeIndexingMetadata.value.default_chunk_size ||
      knowledgeIndexingMetadata.value.chunk_size ||
      20000
  )
);
const storedKnowledgeChunkSize = computed(() =>
  Number(
    runtime.value.knowledge_chunk_size ||
      knowledgeIndexingMetadata.value.chunk_size ||
      knowledgeChunkDefault.value
  )
);
const knowledgeChunkSizeOptions = computed(() => {
  const options = Array.isArray(
    knowledgeIndexingMetadata.value.chunk_size_options
  )
    ? knowledgeIndexingMetadata.value.chunk_size_options
    : [];
  const supportedOptions = options.filter(
    option =>
      option.disabled !== true && Number(option.available_model_count || 0) > 0
  );

  return supportedOptions.map(option => {
    const labelParams = {
      chars: numberFormatter.format(option.value),
      tokens: numberFormatter.format(option.estimated_tokens),
      count: numberFormatter.format(option.available_model_count),
    };

    return {
      value: Number(option.value),
      label: t(
        'CAPTAIN_SETTINGS.MODEL_CONFIG.EMBEDDINGS.CHUNK_SIZE_OPTION',
        labelParams
      ),
      disabled: false,
    };
  });
});

const moderationFailureModeOptions = computed(() => [
  {
    value: 'fail_open',
    label: t(
      'CAPTAIN_SETTINGS.RUNTIME.MODERATION_FAILURE_MODE.OPTIONS.FAIL_OPEN'
    ),
  },
  {
    value: 'fail_closed',
    label: t(
      'CAPTAIN_SETTINGS.RUNTIME.MODERATION_FAILURE_MODE.OPTIONS.FAIL_CLOSED'
    ),
  },
]);
const thinkingOptions = computed(() => [
  {
    value: 'none',
    label: t('CAPTAIN_SETTINGS.RUNTIME.THINKING.OPTIONS.NONE'),
  },
  {
    value: 'low',
    label: t('CAPTAIN_SETTINGS.RUNTIME.THINKING.OPTIONS.LOW'),
  },
  {
    value: 'medium',
    label: t('CAPTAIN_SETTINGS.RUNTIME.THINKING.OPTIONS.MEDIUM'),
  },
  {
    value: 'high',
    label: t('CAPTAIN_SETTINGS.RUNTIME.THINKING.OPTIONS.HIGH'),
  },
]);
const labelSuggestionModelCount = computed(
  () => captainConfigStore.getModelsForFeature('label_suggestion').length
);
const selectedAudioTranscriptionModel = computed(() => {
  const modelId = captainConfigStore.getSelectedModelForFeature(
    'audio_transcription'
  );

  return (
    captainConfigStore
      .getModelsForFeature('audio_transcription')
      .find(model => model.id === modelId) || null
  );
});
const showAudioTranscriptionPrompt = computed(() =>
  shouldShowAudioTranscriptionPrompt(selectedAudioTranscriptionModel.value)
);
const isAudioTranscriptionEnabled = computed(
  () => features.value.audio_transcription?.enabled === true
);
const isHelpCenterSearchEnabled = computed(
  () => features.value.help_center_search?.enabled === true
);
const isLabelSuggestionEnabled = computed(
  () => features.value.label_suggestion?.enabled === true
);

const selectedModelSupportsThinking = featureKey =>
  features.value?.[featureKey]?.selected_supports_thinking === true;

const isRuntimeThinkingDisabled = feature =>
  !isFeatureAccessible(feature) || !selectedModelSupportsThinking(feature.key);

const isAudioTranscriptionPromptDirty = computed(
  () => audioTranscriptionPrompt.value !== storedAudioTranscriptionPrompt.value
);
const isKnowledgeChunkSizeDirty = computed(
  () => Number(knowledgeChunkSize.value) !== storedKnowledgeChunkSize.value
);

const visibleProviderKeyOrder = [
  'openrouter',
  // 'openai',
  // 'anthropic',
  // 'gemini',
];

const providerKeyCards = computed(() => {
  return visibleProviderKeyOrder
    .map(key => {
      const provider = providers.value?.[key];
      const credential = providerCredentials.value[key] || {};

      if (!provider && !credential.display_name) return null;

      return {
        key,
        displayName:
          providerCredentials.value[key]?.display_name ||
          provider?.display_name ||
          key,
        credential,
      };
    })
    .filter(Boolean);
});
const providerCredentialStatus = provider => {
  switch (provider.credential.source) {
    case 'account':
      return t('CAPTAIN_SETTINGS.PROVIDER_KEYS.STATUS.ACCOUNT');
    case 'global':
      return t('CAPTAIN_SETTINGS.PROVIDER_KEYS.STATUS.GLOBAL');
    default:
      return t('CAPTAIN_SETTINGS.PROVIDER_KEYS.STATUS.MISSING');
  }
};
const isProviderApiKeyDirty = providerKey =>
  providerApiKeys[providerKey]?.trim().length > 0;
const selectedKnowledgeChunkOption = computed(() =>
  knowledgeIndexingMetadata.value.chunk_size_options?.find(
    option => Number(option.value) === Number(knowledgeChunkSize.value)
  )
);
const selectedKnowledgeChunkEstimatedTokens = computed(
  () =>
    selectedKnowledgeChunkOption.value?.estimated_tokens ||
    Math.ceil(Number(knowledgeChunkSize.value || 0) / 4)
);
const embeddingModelsForSelectedChunk = computed(() =>
  captainConfigStore.getModelsForFeature('help_center_search').filter(model => {
    const contextLength = Number(model.context_length || 0);
    const modelVectorDimensions = Number(
      model.requested_embedding_dimensions || model.embedding_dimensions || 0
    );
    const supportsVectorDimensions =
      !modelVectorDimensions ||
      modelVectorDimensions === knowledgeVectorDimensions.value;

    return (
      supportsVectorDimensions &&
      contextLength > 0 &&
      contextLength >= selectedKnowledgeChunkEstimatedTokens.value
    );
  })
);
const modelsForFeature = featureKey => {
  if (featureKey === 'help_center_search') {
    return embeddingModelsForSelectedChunk.value;
  }

  return null;
};

watch(
  storedAudioTranscriptionPrompt,
  value => {
    audioTranscriptionPrompt.value = value;
  },
  { immediate: true }
);

watch(
  storedKnowledgeChunkSize,
  value => {
    knowledgeChunkSize.value = value;
  },
  { immediate: true }
);

watch(
  runtime,
  value => {
    moderationFailureMode.value = value.moderation_failure_mode || 'fail_open';
    runtimeThinkingEfforts.value = {
      assistant: value.assistant_thinking_effort || 'none',
      copilot: value.copilot_thinking_effort || 'none',
    };
  },
  { immediate: true, deep: true }
);

async function handleFeatureToggle({ feature, enabled }) {
  try {
    await captainConfigStore.updatePreferences({
      captain_features: { [feature]: enabled },
    });
    useAlert(t('CAPTAIN_SETTINGS.API.SUCCESS'));
  } catch (error) {
    useAlert(t('CAPTAIN_SETTINGS.API.ERROR'));
    captainConfigStore.fetch();
  }
}

async function handleModelChange({ feature, model }) {
  try {
    await captainConfigStore.updatePreferences({
      captain_models: { [feature]: model },
    });
    useAlert(t('CAPTAIN_SETTINGS.API.SUCCESS'));
  } catch (error) {
    useAlert(t('CAPTAIN_SETTINGS.API.ERROR'));
    captainConfigStore.fetch();
  }
}

async function handleRuntimeChange(runtimeConfig) {
  try {
    await captainConfigStore.updatePreferences({
      captain_runtime: runtimeConfig,
    });
    useAlert(t('CAPTAIN_SETTINGS.API.SUCCESS'));
  } catch (error) {
    useAlert(t('CAPTAIN_SETTINGS.API.ERROR'));
    captainConfigStore.fetch();
  }
}

function runtimeModerationEnabled(featureKey) {
  return runtime.value[`${featureKey}_moderation`] === true;
}

async function handleRuntimeModerationChange(featureKey, enabled) {
  await handleRuntimeChange({
    [`${featureKey}_moderation`]: enabled,
  });
}

async function handleRuntimeThinkingChange(featureKey) {
  await handleRuntimeChange({
    [`${featureKey}_thinking_effort`]:
      runtimeThinkingEfforts.value[featureKey] || 'none',
  });
}

async function handleModerationFailureModeChange() {
  await handleRuntimeChange({
    moderation_failure_mode: moderationFailureMode.value || 'fail_open',
  });
}

async function handleAudioTranscriptionPromptSave() {
  await handleRuntimeChange({
    audio_transcription_prompt: audioTranscriptionPrompt.value,
  });
}

async function handleKnowledgeChunkSizeChange(event) {
  event?.stopPropagation?.();
  if (!isKnowledgeChunkSizeDirty.value) return;

  const previousChunkSize = storedKnowledgeChunkSize.value;
  const nextChunkSize = Number(knowledgeChunkSize.value);
  captainConfigStore.patchRuntime({
    knowledge_chunk_size: nextChunkSize,
  });

  try {
    const response = await captainConfigStore.updatePreferences(
      {
        captain_runtime: {
          knowledge_chunk_size: nextChunkSize,
        },
      },
      { applyPayload: false }
    );
    const responsePayload = response.data || {};
    captainConfigStore.patchRuntime(
      responsePayload.runtime || { knowledge_chunk_size: nextChunkSize }
    );
    captainConfigStore.patchRuntimeMetadata(responsePayload.runtime_metadata);
    captainConfigStore.patchFeature(
      'help_center_search',
      responsePayload.features?.help_center_search
    );
    useAlert(t('CAPTAIN_SETTINGS.API.SUCCESS'));
  } catch (error) {
    knowledgeChunkSize.value = previousChunkSize;
    captainConfigStore.patchRuntime({
      knowledge_chunk_size: previousChunkSize,
    });
    useAlert(t('CAPTAIN_SETTINGS.API.ERROR'));
  }
}

async function handleProviderApiKeySave(providerKey) {
  try {
    await captainConfigStore.updatePreferences({
      provider_credentials: {
        [providerKey]: {
          api_key: providerApiKeys[providerKey],
        },
      },
    });
    providerApiKeys[providerKey] = '';
    useAlert(t('CAPTAIN_SETTINGS.PROVIDER_KEYS.SAVE_SUCCESS'));
  } catch (error) {
    useAlert(t('CAPTAIN_SETTINGS.PROVIDER_KEYS.SAVE_ERROR'));
    captainConfigStore.fetch();
  }
}

async function handleProviderApiKeyRemove(providerKey) {
  try {
    await captainConfigStore.updatePreferences({
      provider_credentials: {
        [providerKey]: {
          remove: true,
        },
      },
    });
    providerApiKeys[providerKey] = '';
    useAlert(t('CAPTAIN_SETTINGS.PROVIDER_KEYS.REMOVE_SUCCESS'));
  } catch (error) {
    useAlert(t('CAPTAIN_SETTINGS.PROVIDER_KEYS.REMOVE_ERROR'));
    captainConfigStore.fetch();
  }
}

onMounted(() => {
  captainConfigStore.fetch();
});
</script>

<template>
  <SettingsLayout
    :is-loading="isLoading"
    :no-records-message="t('CAPTAIN_SETTINGS.NOT_ENABLED')"
    :loading-message="t('CAPTAIN_SETTINGS.LOADING')"
  >
    <template #header>
      <BaseSettingsHeader
        :title="t('CAPTAIN_SETTINGS.TITLE')"
        :description="t('CAPTAIN_SETTINGS.DESCRIPTION')"
        icon-name="captain"
      />
    </template>
    <template #body>
      <div v-if="captainEnabled" class="flex flex-col gap-8">
        <SectionLayout
          :title="t('CAPTAIN_SETTINGS.PROVIDER_KEYS.TITLE')"
          :description="t('CAPTAIN_SETTINGS.PROVIDER_KEYS.DESCRIPTION')"
        >
          <div class="grid gap-3">
            <div
              v-for="provider in providerKeyCards"
              :key="provider.key"
              class="grid w-full gap-3 rounded-xl border border-n-weak bg-n-solid-1 p-4"
            >
              <div class="flex items-start justify-between gap-3">
                <div class="flex min-w-0 items-start gap-3">
                  <Icon
                    icon="i-lucide-key-round"
                    class="mt-0.5 size-4 shrink-0 text-n-slate-11"
                  />
                  <div class="min-w-0">
                    <div class="text-sm font-medium text-n-slate-12">
                      {{ provider.displayName }}
                    </div>
                    <div class="mt-0.5 text-xs text-n-slate-11">
                      {{
                        t('CAPTAIN_SETTINGS.PROVIDER_KEYS.STATUS_LABEL', {
                          status: providerCredentialStatus(provider),
                        })
                      }}
                    </div>
                  </div>
                </div>
                <span
                  class="shrink-0 rounded-md border border-n-weak bg-n-alpha-2 px-2 py-1 text-[11px] font-medium text-n-slate-11"
                >
                  {{ providerCredentialStatus(provider) }}
                </span>
              </div>

              <div class="flex flex-col gap-3 md:flex-row md:items-center">
                <div class="min-w-0 flex-1">
                  <Input
                    v-model="providerApiKeys[provider.key]"
                    type="password"
                    :placeholder="
                      t('CAPTAIN_SETTINGS.PROVIDER_KEYS.PLACEHOLDER', {
                        provider: provider.displayName,
                      })
                    "
                  />
                </div>
                <div class="flex shrink-0 gap-2">
                  <NextButton
                    sm
                    blue
                    type="button"
                    :disabled="!isProviderApiKeyDirty(provider.key)"
                    @click="handleProviderApiKeySave(provider.key)"
                  >
                    {{ t('CAPTAIN_SETTINGS.PROVIDER_KEYS.SAVE') }}
                  </NextButton>
                  <NextButton
                    sm
                    ghost
                    ruby
                    type="button"
                    icon="i-lucide-trash-2"
                    :disabled="!provider.credential.account_configured"
                    :title="
                      t('CAPTAIN_SETTINGS.PROVIDER_KEYS.REMOVE_ACCOUNT_KEY')
                    "
                    :aria-label="
                      t('CAPTAIN_SETTINGS.PROVIDER_KEYS.REMOVE_ACCOUNT_KEY')
                    "
                    @click="handleProviderApiKeyRemove(provider.key)"
                  />
                </div>
              </div>
              <p class="text-xs text-n-slate-11">
                {{ t('CAPTAIN_SETTINGS.PROVIDER_KEYS.SECRET_NOTE') }}
              </p>
            </div>
          </div>
        </SectionLayout>

        <!-- Model Configuration Section -->
        <SectionLayout
          :title="t('CAPTAIN_SETTINGS.MODEL_CONFIG.TITLE')"
          :description="t('CAPTAIN_SETTINGS.MODEL_CONFIG.DESCRIPTION')"
        >
          <div class="grid gap-5">
            <ModelSelector
              v-for="feature in modelFeatures"
              v-show="shouldShowFeature(feature)"
              :key="feature.key"
              :is-allowed="isFeatureAccessible(feature)"
              :feature-key="feature.key"
              :title="feature.title"
              :description="feature.description"
              @change="handleModelChange"
            >
              <template #controls>
                <div
                  v-if="feature.key === 'editor'"
                  class="grid gap-4 border-t border-n-weak pt-4"
                >
                  <div class="flex min-w-0 items-center justify-between gap-4">
                    <div class="flex min-w-0 items-start gap-3">
                      <Icon
                        icon="i-lucide-tags"
                        class="mt-0.5 size-4 shrink-0 text-n-slate-11"
                      />
                      <div class="min-w-0">
                        <div class="text-xs font-medium text-n-slate-12">
                          {{
                            t(
                              'CAPTAIN_SETTINGS.FEATURES.LABEL_SUGGESTION.TITLE'
                            )
                          }}
                        </div>
                        <div class="mt-0.5 text-xs text-n-slate-11">
                          {{
                            t(
                              'CAPTAIN_SETTINGS.FEATURES.LABEL_SUGGESTION.DESCRIPTION'
                            )
                          }}
                        </div>
                      </div>
                    </div>
                    <Switch
                      :model-value="isLabelSuggestionEnabled"
                      :disabled="!isFeatureAccessible(feature)"
                      @change="
                        enabled =>
                          handleFeatureToggle({
                            feature: 'label_suggestion',
                            enabled,
                          })
                      "
                    />
                  </div>

                  <div
                    v-if="
                      isLabelSuggestionEnabled && labelSuggestionModelCount > 1
                    "
                    class="flex min-w-0 flex-col gap-4 border-t border-n-weak pt-4 sm:flex-row sm:items-center sm:justify-between"
                  >
                    <div class="min-w-0">
                      <div class="text-xs font-medium text-n-slate-12">
                        {{
                          t(
                            'CAPTAIN_SETTINGS.FEATURES.LABEL_SUGGESTION.MODEL_TITLE'
                          )
                        }}
                      </div>
                      <div class="mt-0.5 text-xs text-n-slate-11">
                        {{
                          t(
                            'CAPTAIN_SETTINGS.FEATURES.LABEL_SUGGESTION.MODEL_DESCRIPTION'
                          )
                        }}
                      </div>
                    </div>
                    <ModelDropdown
                      feature-key="label_suggestion"
                      :feature-title="
                        t('CAPTAIN_SETTINGS.FEATURES.LABEL_SUGGESTION.TITLE')
                      "
                      @change="handleModelChange"
                    />
                  </div>
                </div>

                <div
                  v-else-if="
                    feature.key === 'assistant' || feature.key === 'copilot'
                  "
                  class="grid gap-5 border-t border-n-weak pt-4 md:grid-cols-2"
                >
                  <div class="flex min-w-0 items-start gap-3">
                    <Icon
                      icon="i-lucide-shield-check"
                      class="mt-0.5 size-4 shrink-0 text-n-slate-11"
                    />
                    <div class="min-w-0">
                      <div class="flex min-w-0 items-center gap-3">
                        <div class="text-xs font-medium text-n-slate-12">
                          {{ t('CAPTAIN_SETTINGS.RUNTIME.MODERATION.TITLE') }}
                        </div>
                        <Switch
                          :model-value="runtimeModerationEnabled(feature.key)"
                          :disabled="!isFeatureAccessible(feature)"
                          @change="
                            enabled =>
                              handleRuntimeModerationChange(
                                feature.key,
                                enabled
                              )
                          "
                        />
                      </div>
                      <div class="mt-0.5 text-xs text-n-slate-11">
                        {{
                          t('CAPTAIN_SETTINGS.RUNTIME.MODERATION.DESCRIPTION')
                        }}
                      </div>
                    </div>
                  </div>

                  <div
                    class="flex min-w-0 flex-col gap-2 sm:flex-row sm:items-center sm:justify-between"
                  >
                    <div class="flex min-w-0 items-start gap-3">
                      <Icon
                        icon="i-lucide-brain"
                        class="mt-0.5 size-4 shrink-0 text-n-slate-11"
                      />
                      <div class="min-w-0">
                        <div class="text-xs font-medium text-n-slate-12">
                          {{ t('CAPTAIN_SETTINGS.RUNTIME.THINKING.TITLE') }}
                        </div>
                        <div class="mt-0.5 text-xs text-n-slate-11">
                          {{
                            t('CAPTAIN_SETTINGS.RUNTIME.THINKING.DESCRIPTION')
                          }}
                        </div>
                      </div>
                    </div>
                    <NextSelect
                      v-model="runtimeThinkingEfforts[feature.key]"
                      class="min-w-40"
                      :options="thinkingOptions"
                      :disabled="isRuntimeThinkingDisabled(feature)"
                      @change="handleRuntimeThinkingChange(feature.key)"
                    />
                  </div>
                </div>
              </template>
            </ModelSelector>
          </div>
        </SectionLayout>

        <SectionLayout
          :title="t('CAPTAIN_SETTINGS.MODEL_CONFIG.SPECIALIZED_TITLE')"
          :description="
            t('CAPTAIN_SETTINGS.MODEL_CONFIG.SPECIALIZED_DESCRIPTION')
          "
          with-border
        >
          <div class="grid gap-5">
            <ModelSelector
              v-for="feature in specializedModelFeatures"
              v-show="shouldShowFeature(feature)"
              :key="feature.key"
              :is-allowed="isFeatureAccessible(feature)"
              :feature-key="feature.key"
              :title="feature.title"
              :description="feature.description"
              :models="modelsForFeature(feature.key)"
              :show-controls="feature.key !== 'image_recognition'"
              @change="handleModelChange"
            >
              <template #controls>
                <div
                  v-if="feature.key === 'moderation'"
                  class="flex min-w-0 flex-col gap-4 border-t border-n-weak pt-4 sm:flex-row sm:items-center sm:justify-between"
                >
                  <div class="flex min-w-0 items-start gap-3">
                    <Icon
                      icon="i-lucide-shield-alert"
                      class="mt-0.5 size-4 shrink-0 text-n-slate-11"
                    />
                    <div class="min-w-0">
                      <div class="text-xs font-medium text-n-slate-12">
                        {{
                          t(
                            'CAPTAIN_SETTINGS.RUNTIME.MODERATION_FAILURE_MODE.TITLE'
                          )
                        }}
                      </div>
                      <div class="mt-0.5 text-xs text-n-slate-11">
                        {{
                          t(
                            'CAPTAIN_SETTINGS.RUNTIME.MODERATION_FAILURE_MODE.DESCRIPTION'
                          )
                        }}
                      </div>
                    </div>
                  </div>
                  <NextSelect
                    v-model="moderationFailureMode"
                    class="min-w-56"
                    :options="moderationFailureModeOptions"
                    :disabled="!isFeatureAccessible(feature)"
                    @change="handleModerationFailureModeChange"
                  />
                </div>

                <div
                  v-else-if="feature.key === 'audio_transcription'"
                  class="grid gap-4 border-t border-n-weak pt-4"
                >
                  <div class="flex min-w-0 items-center justify-between gap-4">
                    <div class="flex min-w-0 items-start gap-4">
                      <Icon
                        icon="i-lucide-audio-lines"
                        class="mt-0.5 size-4 shrink-0 text-n-slate-11"
                      />
                      <div class="min-w-0">
                        <div class="text-xs font-medium text-n-slate-12">
                          {{
                            t(
                              'CAPTAIN_SETTINGS.MODEL_CONFIG.AUDIO_TRANSCRIPTION.ENABLE_TITLE'
                            )
                          }}
                        </div>
                        <div class="mt-0.5 text-xs text-n-slate-11">
                          {{
                            t(
                              'CAPTAIN_SETTINGS.MODEL_CONFIG.AUDIO_TRANSCRIPTION.ENABLE_DESCRIPTION'
                            )
                          }}
                        </div>
                      </div>
                    </div>
                    <Switch
                      :model-value="isAudioTranscriptionEnabled"
                      :disabled="!isFeatureAccessible(feature)"
                      @change="
                        enabled =>
                          handleFeatureToggle({
                            feature: 'audio_transcription',
                            enabled,
                          })
                      "
                    />
                  </div>

                  <div
                    v-if="showAudioTranscriptionPrompt"
                    class="grid gap-3 border-t border-n-weak pt-4"
                  >
                    <div class="flex min-w-0 items-start gap-4">
                      <Icon
                        icon="i-lucide-message-square-text"
                        class="mt-0.5 size-4 shrink-0 text-n-slate-11"
                      />
                      <div class="min-w-0">
                        <div class="text-xs font-medium text-n-slate-12">
                          {{
                            t(
                              'CAPTAIN_SETTINGS.MODEL_CONFIG.AUDIO_TRANSCRIPTION.PROMPT_TITLE'
                            )
                          }}
                        </div>
                        <div class="mt-0.5 text-xs text-n-slate-11">
                          {{
                            t(
                              'CAPTAIN_SETTINGS.MODEL_CONFIG.AUDIO_TRANSCRIPTION.PROMPT_DESCRIPTION'
                            )
                          }}
                        </div>
                      </div>
                    </div>
                    <TextArea
                      v-model="audioTranscriptionPrompt"
                      :disabled="!isFeatureAccessible(feature)"
                      :placeholder="
                        t(
                          'CAPTAIN_SETTINGS.MODEL_CONFIG.AUDIO_TRANSCRIPTION.PROMPT_PLACEHOLDER'
                        )
                      "
                      :max-length="2000"
                      show-character-count
                      auto-height
                      resize
                      min-height="4rem"
                      max-height="12rem"
                    />
                    <div class="flex justify-end">
                      <NextButton
                        sm
                        blue
                        type="button"
                        :disabled="
                          !isFeatureAccessible(feature) ||
                          !isAudioTranscriptionPromptDirty
                        "
                        @click="handleAudioTranscriptionPromptSave"
                      >
                        {{
                          t(
                            'CAPTAIN_SETTINGS.MODEL_CONFIG.AUDIO_TRANSCRIPTION.SAVE_PROMPT'
                          )
                        }}
                      </NextButton>
                    </div>
                  </div>
                  <div
                    v-else
                    class="flex min-w-0 items-start gap-3 border-t border-n-weak pt-4"
                  >
                    <Icon
                      icon="i-lucide-badge-check"
                      class="mt-0.5 size-4 shrink-0 text-n-slate-11"
                    />
                    <div class="min-w-0">
                      <div class="text-xs font-medium text-n-slate-12">
                        {{
                          t(
                            'CAPTAIN_SETTINGS.MODEL_CONFIG.AUDIO_TRANSCRIPTION.NATIVE_PROMPT_TITLE'
                          )
                        }}
                      </div>
                      <div class="mt-0.5 text-xs text-n-slate-11">
                        {{
                          t(
                            'CAPTAIN_SETTINGS.MODEL_CONFIG.AUDIO_TRANSCRIPTION.NATIVE_PROMPT_DESCRIPTION'
                          )
                        }}
                      </div>
                    </div>
                  </div>
                </div>

                <div
                  v-else-if="feature.key === 'help_center_search'"
                  class="grid gap-4 border-t border-n-weak pt-4"
                >
                  <div class="flex min-w-0 items-center justify-between gap-4">
                    <div class="flex min-w-0 items-start gap-3">
                      <Icon
                        icon="i-lucide-database-zap"
                        class="mt-0.5 size-4 shrink-0 text-n-slate-11"
                      />
                      <div class="min-w-0">
                        <div class="text-xs font-medium text-n-slate-12">
                          {{
                            t(
                              'CAPTAIN_SETTINGS.MODEL_CONFIG.EMBEDDINGS.INDEXING_TITLE'
                            )
                          }}
                        </div>
                        <div class="mt-0.5 text-xs text-n-slate-11">
                          {{
                            t(
                              'CAPTAIN_SETTINGS.MODEL_CONFIG.EMBEDDINGS.INDEXING_DESCRIPTION'
                            )
                          }}
                        </div>
                      </div>
                    </div>
                    <Switch
                      :model-value="isHelpCenterSearchEnabled"
                      :disabled="!isFeatureAccessible(feature)"
                      @change="
                        enabled =>
                          handleFeatureToggle({
                            feature: 'help_center_search',
                            enabled,
                          })
                      "
                    />
                  </div>

                  <div
                    class="flex min-w-0 flex-col gap-4 border-t border-n-weak pt-4 sm:flex-row sm:items-center sm:justify-between"
                  >
                    <div class="flex min-w-0 items-start gap-3">
                      <Icon
                        icon="i-lucide-spline"
                        class="mt-0.5 size-4 shrink-0 text-n-slate-11"
                      />
                      <div class="min-w-0">
                        <div class="text-xs font-medium text-n-slate-12">
                          {{
                            t(
                              'CAPTAIN_SETTINGS.MODEL_CONFIG.EMBEDDINGS.CHUNK_SIZE_TITLE'
                            )
                          }}
                        </div>
                        <div class="mt-0.5 text-xs text-n-slate-11">
                          {{
                            t(
                              'CAPTAIN_SETTINGS.MODEL_CONFIG.EMBEDDINGS.CHUNK_SIZE_DESCRIPTION'
                            )
                          }}
                        </div>
                      </div>
                    </div>
                    <NextSelect
                      v-model="knowledgeChunkSize"
                      class="min-w-[18rem]"
                      :options="knowledgeChunkSizeOptions"
                      :disabled="
                        !isFeatureAccessible(feature) ||
                        knowledgeChunkSizeOptions.length === 0
                      "
                      @change="handleKnowledgeChunkSizeChange"
                    />
                  </div>
                </div>
              </template>
            </ModelSelector>
          </div>
        </SectionLayout>
      </div>
      <div v-else>
        <CaptainPaywall />
      </div>
    </template>
  </SettingsLayout>
</template>
