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

const props = defineProps({
  section: {
    type: String,
    default: 'settings',
  },
});

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
  usage,
  providerCredentials,
  features,
} = storeToRefs(captainConfigStore);

const isLoading = computed(() => uiFlags.value.isFetching);
const isUsagePage = computed(() => props.section === 'usage');
const audioTranscriptionPrompt = ref('');
const knowledgeChunkSize = ref(0);
const moderationFailureMode = ref('fail_open');
const runtimeThinkingEfforts = ref({
  assistant: 'none',
  copilot: 'none',
});
const runtimeGuardrailActions = ref({
  assistant: {
    prompt_injection: 'block',
    sensitive_info: 'block',
  },
  copilot: {
    prompt_injection: 'block',
    sensitive_info: 'block',
  },
});
const providerApiKeys = reactive({});
const numberFormatter = new Intl.NumberFormat();
const compactNumberFormatter = new Intl.NumberFormat(undefined, {
  notation: 'compact',
  maximumFractionDigits: 1,
});

const currencyFormatter = computed(
  () =>
    new Intl.NumberFormat(undefined, {
      style: 'currency',
      currency: usage.value?.currency || 'USD',
      maximumFractionDigits: 4,
    })
);

function formatCurrency(value) {
  const numberValue = Number(value || 0);
  return currencyFormatter.value.format(
    Number.isFinite(numberValue) ? numberValue : 0
  );
}

function formatNumber(value, { compact = false } = {}) {
  const numberValue = Number(value || 0);
  const formatter = compact ? compactNumberFormatter : numberFormatter;
  return formatter.format(Number.isFinite(numberValue) ? numberValue : 0);
}

function formatPercent(value) {
  const numberValue = Number(value || 0);
  if (!Number.isFinite(numberValue)) return '0';

  return numberFormatter.format(Math.min(100, Math.max(0, numberValue)));
}

function formatRate(value) {
  return `${formatPercent(Number(value || 0) * 100)}%`;
}

function providerHealthStatus(provider) {
  const status = provider.credential.health?.status || 'not_checked';

  switch (status) {
    case 'valid':
      return t('CAPTAIN_SETTINGS.PROVIDER_KEYS.HEALTH_STATUS.VALID');
    case 'missing':
      return t('CAPTAIN_SETTINGS.PROVIDER_KEYS.HEALTH_STATUS.MISSING');
    case 'invalid':
      return t('CAPTAIN_SETTINGS.PROVIDER_KEYS.HEALTH_STATUS.INVALID');
    case 'expired':
      return t('CAPTAIN_SETTINGS.PROVIDER_KEYS.HEALTH_STATUS.EXPIRED');
    case 'unavailable':
      return t('CAPTAIN_SETTINGS.PROVIDER_KEYS.HEALTH_STATUS.UNAVAILABLE');
    case 'credits_exhausted':
      return t(
        'CAPTAIN_SETTINGS.PROVIDER_KEYS.HEALTH_STATUS.CREDITS_EXHAUSTED'
      );
    case 'credits_unavailable':
      return t(
        'CAPTAIN_SETTINGS.PROVIDER_KEYS.HEALTH_STATUS.CREDITS_UNAVAILABLE'
      );
    case 'key_limit_exhausted':
      return t(
        'CAPTAIN_SETTINGS.PROVIDER_KEYS.HEALTH_STATUS.KEY_LIMIT_EXHAUSTED'
      );
    case 'management_key_required':
      return t(
        'CAPTAIN_SETTINGS.PROVIDER_KEYS.HEALTH_STATUS.MANAGEMENT_KEY_REQUIRED'
      );
    case 'workspace_key_configured':
      return t(
        'CAPTAIN_SETTINGS.PROVIDER_KEYS.HEALTH_STATUS.WORKSPACE_KEY_CONFIGURED'
      );
    default:
      return t('CAPTAIN_SETTINGS.PROVIDER_KEYS.HEALTH_STATUS.NOT_CHECKED');
  }
}

function progressWidth(value) {
  const numberValue = Number(value || 0);
  if (!Number.isFinite(numberValue)) return '0%';

  return `${Math.min(100, Math.max(0, numberValue))}%`;
}

function formatDateTime(value) {
  if (!value) return t('CAPTAIN_SETTINGS.USAGE.NEVER');

  const date = new Date(value);
  if (Number.isNaN(date.getTime())) return t('CAPTAIN_SETTINGS.USAGE.NEVER');

  return new Intl.DateTimeFormat(undefined, {
    day: '2-digit',
    month: 'short',
    hour: '2-digit',
    minute: '2-digit',
  }).format(date);
}

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
const guardrailActionOptions = computed(() => [
  {
    value: 'block',
    label: t('CAPTAIN_SETTINGS.RUNTIME.GUARDRAILS.OPTIONS.BLOCK'),
  },
  {
    value: 'flag',
    label: t('CAPTAIN_SETTINGS.RUNTIME.GUARDRAILS.OPTIONS.FLAG'),
  },
  {
    value: 'disabled',
    label: t('CAPTAIN_SETTINGS.RUNTIME.GUARDRAILS.OPTIONS.DISABLED'),
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
const usageWindows = computed(() => usage.value?.windows || {});
const usageToday = computed(() => usageWindows.value.today || {});
const usageMonth = computed(() => usageWindows.value.month || {});
const runtimeHealth = computed(() => usage.value?.runtime_health || {});
const openRouterKeyHealth = computed(() => usage.value?.key_health || {});
const topUsageModels = computed(() =>
  Array.isArray(usage.value?.top_models) ? usage.value.top_models : []
);
const recentUsageErrors = computed(() =>
  Array.isArray(usage.value?.recent_errors) ? usage.value.recent_errors : []
);
function modelCostShare(model) {
  const monthCost = Number(usageMonth.value.estimated_cost || 0);
  if (!monthCost) return 0;

  return (Number(model.estimated_cost || 0) / monthCost) * 100;
}
const runtimeHealthItems = computed(() => [
  {
    key: 'events',
    icon: 'i-lucide-activity',
    label: t('CAPTAIN_SETTINGS.USAGE.RUNTIME_EVENTS'),
    value: formatNumber(runtimeHealth.value.total_events),
  },
  {
    key: 'p95_latency',
    icon: 'i-lucide-timer',
    label: t('CAPTAIN_SETTINGS.USAGE.RUNTIME_P95_LATENCY'),
    value: t('CAPTAIN_SETTINGS.USAGE.MILLISECONDS', {
      count: formatNumber(runtimeHealth.value.p95_duration_ms),
    }),
  },
  {
    key: 'error_rate',
    icon: 'i-lucide-circle-alert',
    label: t('CAPTAIN_SETTINGS.USAGE.RUNTIME_ERROR_RATE'),
    value: formatRate(runtimeHealth.value.error_rate),
  },
  {
    key: 'schema',
    icon: 'i-lucide-braces',
    label: t('CAPTAIN_SETTINGS.USAGE.RUNTIME_SCHEMA_ERRORS'),
    value: formatNumber(runtimeHealth.value.schema_invalid_count),
  },
  {
    key: 'tools',
    icon: 'i-lucide-wrench',
    label: t('CAPTAIN_SETTINGS.USAGE.RUNTIME_TOOL_ERRORS'),
    value: formatNumber(runtimeHealth.value.tool_failure_count),
  },
  {
    key: 'zero_completion',
    icon: 'i-lucide-shield-check',
    label: t('CAPTAIN_SETTINGS.USAGE.RUNTIME_ZERO_COMPLETION'),
    value: formatNumber(runtimeHealth.value.zero_completion_recovered_count),
  },
  {
    key: 'fallback_models',
    icon: 'i-lucide-route',
    label: t('CAPTAIN_SETTINGS.USAGE.RUNTIME_FALLBACKS'),
    value: formatNumber(runtimeHealth.value.fallback_model_count),
  },
  {
    key: 'key_health',
    icon: 'i-lucide-key-round',
    label: t('CAPTAIN_SETTINGS.USAGE.RUNTIME_KEY_HEALTH'),
    value: providerHealthStatus({
      credential: { health: openRouterKeyHealth.value },
    }),
  },
]);

const usageMetricCards = computed(() => [
  {
    key: 'today_spend',
    icon: 'i-lucide-wallet-cards',
    label: t('CAPTAIN_SETTINGS.USAGE.TODAY_SPEND'),
    value: formatCurrency(usageToday.value.estimated_cost),
    detail: t('CAPTAIN_SETTINGS.USAGE.REQUESTS_COUNT', {
      count: formatNumber(usageToday.value.request_count),
    }),
  },
  {
    key: 'month_spend',
    icon: 'i-lucide-chart-column',
    label: t('CAPTAIN_SETTINGS.USAGE.MONTH_SPEND'),
    value: formatCurrency(usageMonth.value.estimated_cost),
    detail: t('CAPTAIN_SETTINGS.USAGE.REQUESTS_COUNT', {
      count: formatNumber(usageMonth.value.request_count),
    }),
  },
  {
    key: 'month_tokens',
    icon: 'i-lucide-coins',
    label: t('CAPTAIN_SETTINGS.USAGE.MONTH_TOKENS'),
    value: formatNumber(usageMonth.value.total_tokens, { compact: true }),
    detail: t('CAPTAIN_SETTINGS.USAGE.CACHED_TOKENS_COUNT', {
      count: formatNumber(usageMonth.value.cached_tokens, { compact: true }),
    }),
  },
  {
    key: 'month_errors',
    icon: 'i-lucide-circle-alert',
    label: t('CAPTAIN_SETTINGS.USAGE.MONTH_ERRORS'),
    value: formatNumber(usageMonth.value.error_count),
    detail: t('CAPTAIN_SETTINGS.USAGE.REASONING_TOKENS_COUNT', {
      count: formatNumber(usageMonth.value.reasoning_tokens, {
        compact: true,
      }),
    }),
  },
]);
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

const visibleProviderKeyOrder = ['openrouter'];

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
const openrouterByokAllowed = computed(
  () => providerCredentials.value.openrouter?.byok_allowed === true
);
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
    runtimeGuardrailActions.value = {
      assistant: {
        prompt_injection: value.assistant_prompt_injection_guardrail || 'block',
        sensitive_info: value.assistant_sensitive_info_guardrail || 'block',
      },
      copilot: {
        prompt_injection: value.copilot_prompt_injection_guardrail || 'block',
        sensitive_info: value.copilot_sensitive_info_guardrail || 'block',
      },
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

async function handleRuntimeGuardrailChange(featureKey, guardrailKey) {
  await handleRuntimeChange({
    [`${featureKey}_${guardrailKey}_guardrail`]:
      runtimeGuardrailActions.value[featureKey]?.[guardrailKey] || 'block',
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
        :title="
          isUsagePage
            ? t('CAPTAIN_SETTINGS.USAGE.TITLE')
            : t('CAPTAIN_SETTINGS.TITLE')
        "
        :description="
          isUsagePage
            ? t('CAPTAIN_SETTINGS.USAGE.DESCRIPTION')
            : t('CAPTAIN_SETTINGS.DESCRIPTION')
        "
        icon-name="captain"
      />
    </template>
    <template #body>
      <div v-if="captainEnabled" class="flex flex-col gap-8">
        <SectionLayout
          v-if="!isUsagePage && openrouterByokAllowed"
          :title="t('CAPTAIN_SETTINGS.PROVIDER_KEYS.TITLE')"
          :description="t('CAPTAIN_SETTINGS.PROVIDER_KEYS.DESCRIPTION')"
        >
          <div class="grid gap-3">
            <div
              v-for="provider in providerKeyCards"
              :key="provider.key"
              class="grid w-full gap-3 rounded-xl border border-n-weak bg-n-solid-1 p-4"
            >
              <div class="flex min-w-0 items-center gap-3">
                <Icon
                  icon="i-lucide-key-round"
                  class="size-4 shrink-0 text-n-slate-11"
                />
                <div class="text-sm font-medium text-n-slate-12">
                  {{ provider.displayName }}
                </div>
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

        <section
          v-if="isUsagePage"
          class="grid gap-5 border-t border-n-weak py-8"
        >
          <div class="grid gap-5" data-test="captain-usage-section">
            <div class="grid gap-3 md:grid-cols-2 xl:grid-cols-4">
              <div
                v-for="metric in usageMetricCards"
                :key="metric.key"
                class="grid gap-3 rounded-xl border border-n-weak bg-n-solid-1 p-4"
              >
                <div class="flex items-center justify-between gap-3">
                  <span class="text-xs font-medium text-n-slate-11">
                    {{ metric.label }}
                  </span>
                  <Icon
                    :icon="metric.icon"
                    class="size-4 shrink-0 text-n-slate-11"
                  />
                </div>
                <div class="text-xl font-semibold text-n-slate-12">
                  {{ metric.value }}
                </div>
                <div class="text-xs text-n-slate-11">
                  {{ metric.detail }}
                </div>
              </div>
            </div>

            <div
              class="grid gap-4 rounded-xl border border-n-weak bg-n-solid-1 p-4"
            >
              <div class="flex min-w-0 items-start gap-3">
                <Icon
                  icon="i-lucide-activity"
                  class="mt-0.5 size-4 shrink-0 text-n-slate-11"
                />
                <div class="min-w-0">
                  <div class="text-sm font-medium text-n-slate-12">
                    {{ t('CAPTAIN_SETTINGS.USAGE.RUNTIME_HEALTH_TITLE') }}
                  </div>
                  <div class="mt-0.5 text-xs text-n-slate-11">
                    {{ t('CAPTAIN_SETTINGS.USAGE.RUNTIME_HEALTH_DESCRIPTION') }}
                  </div>
                </div>
              </div>
              <div class="grid gap-2 sm:grid-cols-2">
                <div
                  v-for="item in runtimeHealthItems"
                  :key="item.key"
                  class="rounded-lg bg-n-alpha-2 p-3"
                >
                  <div class="flex items-center justify-between gap-2">
                    <span class="text-xs text-n-slate-11">
                      {{ item.label }}
                    </span>
                    <Icon
                      :icon="item.icon"
                      class="size-3.5 shrink-0 text-n-slate-11"
                    />
                  </div>
                  <div class="mt-2 text-lg font-semibold text-n-slate-12">
                    {{ item.value }}
                  </div>
                </div>
              </div>
              <div class="rounded-lg bg-n-alpha-2 p-3 text-xs text-n-slate-11">
                {{
                  t('CAPTAIN_SETTINGS.USAGE.LAST_EVENT', {
                    date: formatDateTime(runtimeHealth.last_event_at),
                  })
                }}
              </div>
            </div>

            <div class="grid gap-4 xl:grid-cols-[1.4fr_0.6fr]">
              <div
                class="grid gap-3 rounded-xl border border-n-weak bg-n-solid-1 p-4"
              >
                <div class="flex items-start justify-between gap-3">
                  <div>
                    <div class="text-sm font-medium text-n-slate-12">
                      {{ t('CAPTAIN_SETTINGS.USAGE.TOP_MODELS') }}
                    </div>
                    <div class="mt-0.5 text-xs text-n-slate-11">
                      {{ t('CAPTAIN_SETTINGS.USAGE.TOP_MODELS_DESCRIPTION') }}
                    </div>
                  </div>
                  <Icon
                    icon="i-lucide-list-ordered"
                    class="size-4 shrink-0 text-n-slate-11"
                  />
                </div>
                <div v-if="topUsageModels.length" class="grid gap-2">
                  <div
                    v-for="model in topUsageModels"
                    :key="model.actual_model"
                    class="grid gap-2 rounded-lg bg-n-alpha-2 p-3"
                  >
                    <div class="flex items-start justify-between gap-3">
                      <div class="truncate text-xs font-medium text-n-slate-12">
                        {{ model.actual_model }}
                      </div>
                      <span
                        class="shrink-0 text-xs font-semibold text-n-slate-12"
                      >
                        {{ formatCurrency(model.estimated_cost) }}
                      </span>
                    </div>
                    <div
                      class="flex flex-wrap items-center justify-between gap-2 text-xs text-n-slate-11"
                    >
                      <span>
                        {{
                          t('CAPTAIN_SETTINGS.USAGE.MODEL_USAGE_META', {
                            requests: formatNumber(model.request_count),
                            tokens: formatNumber(model.total_tokens, {
                              compact: true,
                            }),
                          })
                        }}
                      </span>
                      <span>
                        {{
                          t('CAPTAIN_SETTINGS.USAGE.MODEL_COST_SHARE', {
                            percent: formatPercent(modelCostShare(model)),
                          })
                        }}
                      </span>
                    </div>
                    <div
                      class="h-1.5 overflow-hidden rounded-full bg-n-alpha-3"
                    >
                      <div
                        data-test="model-cost-share"
                        class="h-full rounded-full bg-n-blue-9"
                        :style="{ width: progressWidth(modelCostShare(model)) }"
                      />
                    </div>
                  </div>
                </div>
                <div
                  v-else
                  class="rounded-lg bg-n-alpha-2 p-3 text-xs text-n-slate-11"
                >
                  {{ t('CAPTAIN_SETTINGS.USAGE.NO_TOP_MODELS') }}
                </div>
              </div>

              <div
                class="grid gap-3 rounded-xl border border-n-weak bg-n-solid-1 p-4"
              >
                <div class="flex items-center justify-between gap-3">
                  <div class="text-sm font-medium text-n-slate-12">
                    {{ t('CAPTAIN_SETTINGS.USAGE.RECENT_ERRORS') }}
                  </div>
                  <Icon
                    icon="i-lucide-triangle-alert"
                    class="size-4 shrink-0 text-n-slate-11"
                  />
                </div>
                <div v-if="recentUsageErrors.length" class="grid gap-2">
                  <div
                    v-for="error in recentUsageErrors"
                    :key="`${error.occurred_at}-${error.trace_id || error.request_id}`"
                    class="grid gap-1 rounded-lg bg-n-alpha-2 p-3"
                  >
                    <div class="flex items-center justify-between gap-3">
                      <span
                        class="truncate text-xs font-medium text-n-slate-12"
                      >
                        {{ error.error_code || error.status }}
                      </span>
                      <span class="shrink-0 text-[11px] text-n-slate-11">
                        {{ formatDateTime(error.occurred_at) }}
                      </span>
                    </div>
                    <div class="truncate text-xs text-n-slate-11">
                      {{ error.model || error.feature }}
                    </div>
                  </div>
                </div>
                <div
                  v-else
                  class="rounded-lg bg-n-alpha-2 p-3 text-xs text-n-slate-11"
                >
                  {{ t('CAPTAIN_SETTINGS.USAGE.NO_RECENT_ERRORS') }}
                </div>
              </div>
            </div>
          </div>
        </section>

        <!-- Model Configuration Section -->
        <SectionLayout
          v-if="false"
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
                  class="grid gap-5 border-t border-n-weak pt-4 xl:grid-cols-3"
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

                  <div class="grid min-w-0 gap-3">
                    <div class="flex min-w-0 items-start gap-3">
                      <Icon
                        icon="i-lucide-shield-ban"
                        class="mt-0.5 size-4 shrink-0 text-n-slate-11"
                      />
                      <div class="min-w-0">
                        <div class="text-xs font-medium text-n-slate-12">
                          {{ t('CAPTAIN_SETTINGS.RUNTIME.GUARDRAILS.TITLE') }}
                        </div>
                        <div class="mt-0.5 text-xs text-n-slate-11">
                          {{
                            t('CAPTAIN_SETTINGS.RUNTIME.GUARDRAILS.DESCRIPTION')
                          }}
                        </div>
                      </div>
                    </div>
                    <div class="grid gap-2 sm:grid-cols-2 xl:grid-cols-1">
                      <div class="grid min-w-0 gap-1">
                        <span class="text-[11px] font-medium text-n-slate-11">
                          {{
                            t(
                              'CAPTAIN_SETTINGS.RUNTIME.GUARDRAILS.PROMPT_INJECTION'
                            )
                          }}
                        </span>
                        <NextSelect
                          v-model="
                            runtimeGuardrailActions[feature.key]
                              .prompt_injection
                          "
                          :options="guardrailActionOptions"
                          :disabled="!isFeatureAccessible(feature)"
                          @change="
                            handleRuntimeGuardrailChange(
                              feature.key,
                              'prompt_injection'
                            )
                          "
                        />
                      </div>
                      <div class="grid min-w-0 gap-1">
                        <span class="text-[11px] font-medium text-n-slate-11">
                          {{
                            t(
                              'CAPTAIN_SETTINGS.RUNTIME.GUARDRAILS.SENSITIVE_INFO'
                            )
                          }}
                        </span>
                        <NextSelect
                          v-model="
                            runtimeGuardrailActions[feature.key].sensitive_info
                          "
                          :options="guardrailActionOptions"
                          :disabled="!isFeatureAccessible(feature)"
                          @change="
                            handleRuntimeGuardrailChange(
                              feature.key,
                              'sensitive_info'
                            )
                          "
                        />
                      </div>
                    </div>
                  </div>
                </div>
              </template>
            </ModelSelector>
          </div>
        </SectionLayout>

        <SectionLayout
          v-if="false"
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
              :allow-model-selection="feature.key === 'moderation'"
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
