<script setup>
import { computed, onMounted, ref, watch } from 'vue';
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
import FeatureToggle from './components/FeatureToggle.vue';
import RuntimeSettingsCard from './components/RuntimeSettingsCard.vue';
import RuntimeModerationPolicyCard from './components/RuntimeModerationPolicyCard.vue';
import RuntimeStatusCard from './components/RuntimeStatusCard.vue';
import NextButton from 'dashboard/components-next/button/Button.vue';
import Input from 'dashboard/components-next/input/Input.vue';
import TextArea from 'dashboard/components-next/textarea/TextArea.vue';
import CaptainPaywall from 'next/captain/pageComponents/Paywall.vue';

const { t } = useI18n();
const { captainEnabled } = useCaptain();
const { isEnterprise, enterprisePlanName } = useConfig();
const { isOnChatwootCloud } = useAccount();

const captainConfigStore = useCaptainConfigStore();
const { uiFlags, runtime, providerCredentials, features } =
  storeToRefs(captainConfigStore);

const isLoading = computed(() => uiFlags.value.isFetching);
const audioTranscriptionFeature = {
  key: 'audio_transcription',
  enterprise: true,
};
const audioTranscriptionPrompt = ref('');
const openRouterApiKey = ref('');

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
    key: 'help_center_search',
    title: t('CAPTAIN_SETTINGS.MODEL_CONFIG.EMBEDDINGS.TITLE'),
    description: t('CAPTAIN_SETTINGS.MODEL_CONFIG.EMBEDDINGS.DESCRIPTION'),
    enterprise: true,
  },
]);

const featureToggles = computed(() => [
  {
    key: 'label_suggestion',
  },
  {
    key: 'help_center_search',
    enterprise: true,
    showModelSelector: false,
  },
  {
    ...audioTranscriptionFeature,
    showModelSelector: false,
  },
]);

const runtimeFeatures = computed(() => [
  {
    key: 'assistant',
    title: t('CAPTAIN_SETTINGS.RUNTIME.ASSISTANT.TITLE'),
    description: t('CAPTAIN_SETTINGS.RUNTIME.ASSISTANT.DESCRIPTION'),
    enterprise: true,
  },
  {
    key: 'copilot',
    title: t('CAPTAIN_SETTINGS.RUNTIME.COPILOT.TITLE'),
    description: t('CAPTAIN_SETTINGS.RUNTIME.COPILOT.DESCRIPTION'),
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

const isAudioTranscriptionAccessible = computed(() =>
  isFeatureAccessible(audioTranscriptionFeature)
);

const isAudioTranscriptionPromptDirty = computed(
  () => audioTranscriptionPrompt.value !== storedAudioTranscriptionPrompt.value
);
const openRouterCredential = computed(
  () => providerCredentials.value.openrouter || {}
);
const openRouterCredentialStatus = computed(() => {
  switch (openRouterCredential.value.source) {
    case 'account':
      return t('CAPTAIN_SETTINGS.PROVIDER_KEYS.STATUS.ACCOUNT');
    case 'global':
      return t('CAPTAIN_SETTINGS.PROVIDER_KEYS.STATUS.GLOBAL');
    default:
      return t('CAPTAIN_SETTINGS.PROVIDER_KEYS.STATUS.MISSING');
  }
});
const isOpenRouterApiKeyDirty = computed(
  () => openRouterApiKey.value.trim().length > 0
);

const selectedModelDetailsForFeature = featureKey => {
  const feature = features.value[featureKey];
  const selectedModel = feature?.selected || feature?.default;
  return feature?.models?.find(model => model.id === selectedModel) || null;
};

const supportsImageInput = model => {
  return (
    model?.capabilities?.includes('image_input') ||
    model?.capabilities?.includes('multimodal_input')
  );
};

const imageFeatureLabel = featureKey => {
  switch (featureKey) {
    case 'assistant':
      return t(
        'CAPTAIN_SETTINGS.MODEL_CONFIG.IMAGE_UNDERSTANDING.FEATURES.ASSISTANT'
      );
    case 'copilot':
      return t(
        'CAPTAIN_SETTINGS.MODEL_CONFIG.IMAGE_UNDERSTANDING.FEATURES.COPILOT'
      );
    default:
      return featureKey;
  }
};

const imageCapabilityItems = computed(() =>
  ['assistant', 'copilot'].map(featureKey => {
    const model = selectedModelDetailsForFeature(featureKey);
    return {
      key: featureKey,
      label: imageFeatureLabel(featureKey),
      modelName: model?.display_name || '—',
      supported: supportsImageInput(model),
    };
  })
);

watch(
  storedAudioTranscriptionPrompt,
  value => {
    audioTranscriptionPrompt.value = value;
  },
  { immediate: true }
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

async function handleAudioTranscriptionPromptSave() {
  await handleRuntimeChange({
    audio_transcription_prompt: audioTranscriptionPrompt.value,
  });
}

async function handleOpenRouterApiKeySave() {
  try {
    await captainConfigStore.updatePreferences({
      openrouter_api_key: openRouterApiKey.value,
    });
    openRouterApiKey.value = '';
    useAlert(t('CAPTAIN_SETTINGS.PROVIDER_KEYS.SAVE_SUCCESS'));
  } catch (error) {
    useAlert(t('CAPTAIN_SETTINGS.PROVIDER_KEYS.SAVE_ERROR'));
    captainConfigStore.fetch();
  }
}

async function handleOpenRouterApiKeyRemove() {
  try {
    await captainConfigStore.updatePreferences({
      remove_openrouter_api_key: true,
    });
    openRouterApiKey.value = '';
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
      <div v-if="captainEnabled" class="flex flex-col gap-1">
        <SectionLayout
          :title="t('CAPTAIN_SETTINGS.PROVIDER_KEYS.TITLE')"
          :description="t('CAPTAIN_SETTINGS.PROVIDER_KEYS.DESCRIPTION')"
        >
          <div
            class="grid gap-3 rounded-xl border border-n-weak bg-n-solid-1 p-4"
          >
            <div class="flex flex-col gap-1">
              <span class="text-sm font-medium text-n-slate-12">
                {{ t('CAPTAIN_SETTINGS.PROVIDER_KEYS.OPENROUTER_TITLE') }}
              </span>
              <span class="text-sm text-n-slate-11">
                {{
                  t('CAPTAIN_SETTINGS.PROVIDER_KEYS.OPENROUTER_STATUS', {
                    status: openRouterCredentialStatus,
                  })
                }}
              </span>
            </div>
            <div class="flex flex-col gap-3 md:flex-row md:items-center">
              <Input
                v-model="openRouterApiKey"
                type="password"
                :placeholder="
                  t('CAPTAIN_SETTINGS.PROVIDER_KEYS.OPENROUTER_PLACEHOLDER')
                "
              />
              <div class="flex gap-2">
                <NextButton
                  sm
                  blue
                  type="button"
                  :disabled="!isOpenRouterApiKeyDirty"
                  @click="handleOpenRouterApiKeySave"
                >
                  {{ t('CAPTAIN_SETTINGS.PROVIDER_KEYS.SAVE') }}
                </NextButton>
                <NextButton
                  sm
                  faded
                  slate
                  type="button"
                  :disabled="!openRouterCredential.account_configured"
                  @click="handleOpenRouterApiKeyRemove"
                >
                  {{ t('CAPTAIN_SETTINGS.PROVIDER_KEYS.REMOVE_ACCOUNT_KEY') }}
                </NextButton>
              </div>
            </div>
            <p class="text-xs text-n-slate-11">
              {{ t('CAPTAIN_SETTINGS.PROVIDER_KEYS.SECRET_NOTE') }}
            </p>
          </div>
        </SectionLayout>

        <!-- Model Configuration Section -->
        <SectionLayout
          :title="t('CAPTAIN_SETTINGS.MODEL_CONFIG.TITLE')"
          :description="t('CAPTAIN_SETTINGS.MODEL_CONFIG.DESCRIPTION')"
        >
          <div class="grid gap-4">
            <ModelSelector
              v-for="feature in modelFeatures"
              v-show="shouldShowFeature(feature)"
              :key="feature.key"
              :is-allowed="isFeatureAccessible(feature)"
              :feature-key="feature.key"
              :title="feature.title"
              :description="feature.description"
              @change="handleModelChange"
            />
          </div>
        </SectionLayout>

        <SectionLayout
          :title="t('CAPTAIN_SETTINGS.MODEL_CONFIG.SPECIALIZED_TITLE')"
          :description="
            t('CAPTAIN_SETTINGS.MODEL_CONFIG.SPECIALIZED_DESCRIPTION')
          "
          with-border
        >
          <div class="grid gap-4">
            <ModelSelector
              v-for="feature in specializedModelFeatures"
              v-show="shouldShowFeature(feature)"
              :key="feature.key"
              :is-allowed="isFeatureAccessible(feature)"
              :feature-key="feature.key"
              :title="feature.title"
              :description="feature.description"
              @change="handleModelChange"
            />
            <div
              class="grid gap-3 rounded-xl border border-n-weak bg-n-solid-1 p-4"
            >
              <div class="min-w-0">
                <h4 class="text-sm font-medium text-n-slate-12">
                  {{
                    t('CAPTAIN_SETTINGS.MODEL_CONFIG.IMAGE_UNDERSTANDING.TITLE')
                  }}
                </h4>
                <p class="text-sm text-n-slate-11 mt-0.5">
                  {{
                    t(
                      'CAPTAIN_SETTINGS.MODEL_CONFIG.IMAGE_UNDERSTANDING.DESCRIPTION'
                    )
                  }}
                </p>
              </div>
              <div class="grid gap-2 md:grid-cols-2">
                <div
                  v-for="item in imageCapabilityItems"
                  :key="item.key"
                  class="rounded-lg border border-n-weak bg-n-alpha-2 px-3 py-2"
                >
                  <div class="text-sm font-medium text-n-slate-12">
                    {{ item.label }}
                  </div>
                  <div class="text-xs text-n-slate-11 mt-0.5">
                    {{ item.modelName }}
                  </div>
                  <div
                    class="text-xs font-medium mt-1"
                    :class="
                      item.supported ? 'text-n-teal-11' : 'text-n-amber-12'
                    "
                  >
                    {{
                      item.supported
                        ? t(
                            'CAPTAIN_SETTINGS.MODEL_CONFIG.IMAGE_UNDERSTANDING.SUPPORTED'
                          )
                        : t(
                            'CAPTAIN_SETTINGS.MODEL_CONFIG.IMAGE_UNDERSTANDING.NOT_SUPPORTED'
                          )
                    }}
                  </div>
                </div>
              </div>
            </div>
          </div>
        </SectionLayout>

        <!-- Features Section -->
        <SectionLayout
          :title="t('CAPTAIN_SETTINGS.FEATURES.TITLE')"
          :description="t('CAPTAIN_SETTINGS.FEATURES.DESCRIPTION')"
          with-border
        >
          <div class="grid gap-4">
            <FeatureToggle
              v-for="feature in featureToggles"
              v-show="shouldShowFeature(feature)"
              :key="feature.key"
              :is-allowed="isFeatureAccessible(feature)"
              :feature-key="feature.key"
              :show-model-selector="feature.showModelSelector !== false"
              @change="handleFeatureToggle"
              @model-change="handleModelChange"
            />
            <div
              v-show="shouldShowFeature(audioTranscriptionFeature)"
              class="grid gap-3 rounded-xl border border-n-weak bg-n-solid-1 p-4"
              :class="{
                'opacity-60 pointer-events-none':
                  !isAudioTranscriptionAccessible,
              }"
            >
              <div class="min-w-0">
                <h4 class="text-sm font-medium text-n-slate-12">
                  {{
                    t(
                      'CAPTAIN_SETTINGS.FEATURES.AUDIO_TRANSCRIPTION.PROMPT_TITLE'
                    )
                  }}
                </h4>
                <p class="text-sm text-n-slate-11 mt-0.5">
                  {{
                    t(
                      'CAPTAIN_SETTINGS.FEATURES.AUDIO_TRANSCRIPTION.PROMPT_DESCRIPTION'
                    )
                  }}
                </p>
              </div>
              <TextArea
                v-model="audioTranscriptionPrompt"
                :disabled="!isAudioTranscriptionAccessible"
                :placeholder="
                  t(
                    'CAPTAIN_SETTINGS.FEATURES.AUDIO_TRANSCRIPTION.PROMPT_PLACEHOLDER'
                  )
                "
                :max-length="2000"
                show-character-count
                auto-height
                resize
                min-height="5rem"
                max-height="14rem"
              />
              <div class="flex justify-end">
                <NextButton
                  sm
                  blue
                  type="button"
                  :disabled="
                    !isAudioTranscriptionAccessible ||
                    !isAudioTranscriptionPromptDirty
                  "
                  @click="handleAudioTranscriptionPromptSave"
                >
                  {{
                    t(
                      'CAPTAIN_SETTINGS.FEATURES.AUDIO_TRANSCRIPTION.SAVE_PROMPT'
                    )
                  }}
                </NextButton>
              </div>
            </div>
          </div>
        </SectionLayout>

        <SectionLayout
          :title="t('CAPTAIN_SETTINGS.RUNTIME.TITLE')"
          :description="t('CAPTAIN_SETTINGS.RUNTIME.DESCRIPTION')"
          with-border
        >
          <div class="grid gap-4">
            <RuntimeModerationPolicyCard
              :is-allowed="isFeatureAccessible({ enterprise: true })"
              :title="
                t('CAPTAIN_SETTINGS.RUNTIME.MODERATION_FAILURE_MODE.TITLE')
              "
              :description="
                t(
                  'CAPTAIN_SETTINGS.RUNTIME.MODERATION_FAILURE_MODE.DESCRIPTION'
                )
              "
              @change="handleRuntimeChange"
            />
            <RuntimeSettingsCard
              v-for="feature in runtimeFeatures"
              v-show="shouldShowFeature(feature)"
              :key="feature.key"
              :is-allowed="isFeatureAccessible(feature)"
              :feature-key="feature.key"
              :title="feature.title"
              :description="feature.description"
              :moderation-title="t('CAPTAIN_SETTINGS.RUNTIME.MODERATION.TITLE')"
              :moderation-description="
                t('CAPTAIN_SETTINGS.RUNTIME.MODERATION.DESCRIPTION')
              "
              :thinking-title="t('CAPTAIN_SETTINGS.RUNTIME.THINKING.TITLE')"
              :thinking-description="
                t('CAPTAIN_SETTINGS.RUNTIME.THINKING.DESCRIPTION')
              "
              @change="handleRuntimeChange"
            />
          </div>
        </SectionLayout>

        <SectionLayout
          :title="t('CAPTAIN_SETTINGS.RUNTIME_STATUS.SECTION_TITLE')"
          :description="
            t('CAPTAIN_SETTINGS.RUNTIME_STATUS.SECTION_DESCRIPTION')
          "
          with-border
        >
          <RuntimeStatusCard />
        </SectionLayout>
      </div>
      <div v-else>
        <CaptainPaywall />
      </div>
    </template>
  </SettingsLayout>
</template>
