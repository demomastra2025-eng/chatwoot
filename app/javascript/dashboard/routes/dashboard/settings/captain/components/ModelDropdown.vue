<script setup>
import { ref, computed, watch, nextTick } from 'vue';
import { useI18n } from 'vue-i18n';
import { useCaptainConfigStore } from 'dashboard/store/captain/preferences';
import Dialog from 'dashboard/components-next/dialog/Dialog.vue';
import Icon from 'dashboard/components-next/icon/Icon.vue';
import LobeProviderIcon from './LobeProviderIcon.vue';

const props = defineProps({
  featureKey: {
    type: String,
    required: true,
  },
  featureTitle: {
    type: String,
    default: '',
  },
  models: {
    type: Array,
    default: null,
  },
});

const emit = defineEmits(['change']);

const PROVIDER_DISPLAY_NAMES = {
  openai: 'OpenAI',
  anthropic: 'Anthropic',
  mistral: 'Mistral',
  mistralai: 'Mistral',
  gemini: 'Gemini',
  google: 'Google',
  openrouter: 'OpenRouter',
  'meta-llama': 'Meta Llama',
  deepseek: 'DeepSeek',
  qwen: 'Qwen',
  cohere: 'Cohere',
  'x-ai': 'xAI',
  perplexity: 'Perplexity',
  microsoft: 'Microsoft',
  amazon: 'Amazon',
};

const MODALITY_ICONS = {
  text: 'i-lucide-type',
  image: 'i-lucide-image',
  audio: 'i-lucide-volume-2',
  file: 'i-lucide-file',
  pdf: 'i-lucide-file-text',
  video: 'i-lucide-video',
  embeddings: 'i-lucide-binary',
};

const { t } = useI18n();
const captainConfigStore = useCaptainConfigStore();
const dialogRef = ref(null);
const searchInputRef = ref(null);
const searchQuery = ref('');

const availableModels = computed(
  () => props.models || captainConfigStore.getModelsForFeature(props.featureKey)
);

const recommendedModelId = computed(() =>
  captainConfigStore.getDefaultModelForFeature(props.featureKey)
);

const selectedModel = computed(() =>
  captainConfigStore.getSelectedModelForFeature(props.featureKey)
);

const selectedModelId = ref(null);

watch(
  selectedModel,
  newSelected => {
    if (newSelected) {
      selectedModelId.value = newSelected;
    }
  },
  { immediate: true }
);

const selectedModelDetails = computed(() => {
  if (!selectedModelId.value) return null;
  return (
    availableModels.value.find(model => model.id === selectedModelId.value) ||
    null
  );
});

const cleanProviderKey = providerKey =>
  String(providerKey || '')
    .trim()
    .toLowerCase()
    .replace(/^~+/, '');

const masterProviderKeyForModel = model =>
  cleanProviderKey(model.provider || 'unknown');

const modelProviderKeyForModel = model => {
  if (model.provider === 'openrouter' && model.id?.includes('/')) {
    return cleanProviderKey(model.id.split('/')[0]);
  }

  return masterProviderKeyForModel(model);
};

const humanizeProviderKey = providerKey => {
  return cleanProviderKey(providerKey)
    .split(/[-_]/)
    .filter(Boolean)
    .map(part => part.charAt(0).toUpperCase() + part.slice(1))
    .join(' ');
};

const providerDisplayNameForKey = providerKey => {
  return (
    PROVIDER_DISPLAY_NAMES[providerKey] || humanizeProviderKey(providerKey)
  );
};

const masterProviderDisplayName = model =>
  model.provider_display_name ||
  providerDisplayNameForKey(masterProviderKeyForModel(model));

const modelProviderDisplayName = model =>
  providerDisplayNameForKey(modelProviderKeyForModel(model));

const hasSeparateModelProvider = model =>
  modelProviderKeyForModel(model) !== masterProviderKeyForModel(model);

const providerRouteLabel = model =>
  t('CAPTAIN_SETTINGS.MODEL_CONFIG.PROVIDER_ROUTE_LABEL', {
    provider: masterProviderDisplayName(model),
  });

const hasCapability = (model, capability) => {
  return (model.capabilities || []).includes(capability);
};

const inferredModalities = (model, direction) => {
  const capabilities = model.capabilities || [];
  const modalities = [];

  if (direction === 'input') {
    if (capabilities.includes('text_input') || model.type === 'chat') {
      modalities.push('text');
    }
    if (capabilities.includes('image_input')) modalities.push('image');
    if (capabilities.includes('audio_input')) modalities.push('audio');
    if (capabilities.includes('file_input')) modalities.push('file');
    return modalities;
  }

  if (capabilities.includes('text_output') || model.type === 'chat') {
    modalities.push('text');
  }
  if (capabilities.includes('image_output')) modalities.push('image');
  if (capabilities.includes('audio_output')) modalities.push('audio');

  return modalities;
};

const modalitiesFor = (model, direction) => {
  const configured =
    direction === 'input' ? model.input_modalities : model.output_modalities;
  const modalities = configured?.length
    ? configured
    : inferredModalities(model, direction);

  return [
    ...new Set(modalities.filter(Boolean).map(value => value.toString())),
  ];
};

const modalityLabel = modality => {
  const normalized = modality.toLowerCase();

  if (normalized === 'text') {
    return t('CAPTAIN_SETTINGS.MODEL_CONFIG.MODALITIES.TEXT');
  }
  if (normalized === 'image') {
    return t('CAPTAIN_SETTINGS.MODEL_CONFIG.MODALITIES.IMAGE');
  }
  if (normalized === 'audio') {
    return t('CAPTAIN_SETTINGS.MODEL_CONFIG.MODALITIES.AUDIO');
  }
  if (normalized === 'file') {
    return t('CAPTAIN_SETTINGS.MODEL_CONFIG.MODALITIES.FILE');
  }
  if (normalized === 'pdf') {
    return t('CAPTAIN_SETTINGS.MODEL_CONFIG.MODALITIES.PDF');
  }
  if (normalized === 'video') {
    return t('CAPTAIN_SETTINGS.MODEL_CONFIG.MODALITIES.VIDEO');
  }
  if (normalized === 'embeddings') {
    return t('CAPTAIN_SETTINGS.MODEL_CONFIG.MODALITIES.EMBEDDINGS');
  }

  return modality;
};

const modalityIcon = modality => {
  return MODALITY_ICONS[modality.toLowerCase()] || 'i-lucide-circle';
};

const formatModalities = (model, direction) => {
  const modalities = modalitiesFor(model, direction);
  if (!modalities.length) return null;

  return modalities
    .map(modalityLabel)
    .join(t('CAPTAIN_SETTINGS.MODEL_CONFIG.METADATA_SEPARATOR'));
};

const searchableModelText = model => {
  return [
    model.id,
    model.display_name,
    model.provider,
    masterProviderDisplayName(model),
    modelProviderDisplayName(model),
    ...(model.capabilities || []),
    ...modalitiesFor(model, 'input'),
    ...modalitiesFor(model, 'output'),
  ]
    .filter(Boolean)
    .join(' ')
    .toLowerCase();
};

const filteredModels = computed(() => {
  const query = searchQuery.value.trim().toLowerCase();
  if (!query) return availableModels.value;

  return availableModels.value.filter(model =>
    searchableModelText(model).includes(query)
  );
});

const groupedFilteredModels = computed(() => {
  const groupedModels = new Map();

  filteredModels.value.forEach(model => {
    const key = modelProviderKeyForModel(model);
    if (!groupedModels.has(key)) {
      groupedModels.set(key, {
        key,
        name: modelProviderDisplayName(model),
        models: [],
      });
    }

    groupedModels.get(key).models.push(model);
  });

  return [...groupedModels.values()].sort((left, right) =>
    left.name.localeCompare(right.name)
  );
});

const formatTokenCount = value => {
  if (!value) return null;

  return t('CAPTAIN_SETTINGS.MODEL_CONFIG.TOKEN_COUNT', {
    count: new Intl.NumberFormat().format(value),
  });
};

const formatPricePerMillion = price => {
  if (price === undefined || price === null || price === '') {
    return null;
  }

  const perMillion = Number(price) * 1_000_000;
  if (!Number.isFinite(perMillion)) {
    return null;
  }

  const formattedPrice = new Intl.NumberFormat(undefined, {
    style: 'currency',
    currency: 'USD',
    maximumFractionDigits: perMillion < 1 ? 4 : 2,
  }).format(perMillion);

  return t('CAPTAIN_SETTINGS.MODEL_CONFIG.PRICE_PER_MILLION', {
    price: formattedPrice,
  });
};

const formatLatency = value => {
  if (!value) return null;

  return t('CAPTAIN_SETTINGS.MODEL_CONFIG.LATENCY_VALUE', {
    count: new Intl.NumberFormat(undefined, {
      maximumFractionDigits: 0,
    }).format(value),
  });
};

const formatThroughput = value => {
  if (!value) return null;

  return t('CAPTAIN_SETTINGS.MODEL_CONFIG.THROUGHPUT_VALUE', {
    count: new Intl.NumberFormat(undefined, {
      maximumFractionDigits: 1,
    }).format(value),
  });
};

const formatCacheTokenPrice = pricing => {
  return formatPricePerMillion(
    pricing?.input_cache_read ?? pricing?.input_cache_write
  );
};

const supportLabel = supported => {
  return supported
    ? t('CAPTAIN_SETTINGS.MODEL_CONFIG.SUPPORTED')
    : t('CAPTAIN_SETTINGS.MODEL_CONFIG.NOT_SUPPORTED');
};

const metricItems = model =>
  [
    {
      icon: 'i-lucide-log-in',
      label: t('CAPTAIN_SETTINGS.MODEL_CONFIG.INPUT_MODALITIES'),
      modalities: modalitiesFor(model, 'input'),
      title: formatModalities(model, 'input'),
    },
    {
      icon: 'i-lucide-log-out',
      label: t('CAPTAIN_SETTINGS.MODEL_CONFIG.OUTPUT_MODALITIES'),
      modalities: modalitiesFor(model, 'output'),
      title: formatModalities(model, 'output'),
    },
    {
      icon: 'i-lucide-coins',
      label: t('CAPTAIN_SETTINGS.MODEL_CONFIG.INPUT_TOKEN_PRICE'),
      value: formatPricePerMillion(model.pricing?.prompt),
    },
    {
      icon: 'i-lucide-circle-dollar-sign',
      label: t('CAPTAIN_SETTINGS.MODEL_CONFIG.OUTPUT_TOKEN_PRICE'),
      value: formatPricePerMillion(model.pricing?.completion),
    },
    {
      icon: 'i-lucide-archive',
      label: t('CAPTAIN_SETTINGS.MODEL_CONFIG.CACHE_TOKEN_PRICE'),
      value: formatCacheTokenPrice(model.pricing),
    },
    {
      icon: 'i-lucide-panel-top',
      label: t('CAPTAIN_SETTINGS.MODEL_CONFIG.CONTEXT_SIZE'),
      value: formatTokenCount(model.context_length),
    },
    {
      icon: 'i-lucide-message-square-text',
      label: t('CAPTAIN_SETTINGS.MODEL_CONFIG.MAX_OUTPUT'),
      value: formatTokenCount(model.max_output_tokens),
    },
    {
      icon: 'i-lucide-timer',
      label: t('CAPTAIN_SETTINGS.MODEL_CONFIG.LATENCY'),
      value: formatLatency(model.latency_ms),
    },
    {
      icon: 'i-lucide-gauge',
      label: t('CAPTAIN_SETTINGS.MODEL_CONFIG.THROUGHPUT'),
      value: formatThroughput(model.throughput_tokens_per_second),
    },
    {
      icon: 'i-lucide-wrench',
      label: t('CAPTAIN_SETTINGS.MODEL_CONFIG.TOOLS'),
      value: supportLabel(hasCapability(model, 'tool_calling')),
      muted: !hasCapability(model, 'tool_calling'),
    },
    {
      icon: 'i-lucide-braces',
      label: t('CAPTAIN_SETTINGS.MODEL_CONFIG.STRUCTURED_OUTPUT'),
      value: supportLabel(hasCapability(model, 'structured_output')),
      muted: !hasCapability(model, 'structured_output'),
    },
    {
      icon: 'i-lucide-brain',
      label: t('CAPTAIN_SETTINGS.MODEL_CONFIG.REASONING'),
      value: supportLabel(hasCapability(model, 'reasoning')),
      muted: !hasCapability(model, 'reasoning'),
    },
  ].filter(item => item.value || item.modalities?.length);

const openDialog = () => {
  dialogRef.value?.open();
  nextTick(() => searchInputRef.value?.focus());
};

const closeDialog = () => {
  dialogRef.value?.close();
};

const handleDialogClose = () => {
  searchQuery.value = '';
};

const selectModel = model => {
  if (model.coming_soon) return;

  selectedModelId.value = model.id;
  emit('change', { feature: props.featureKey, model: model.id });
  closeDialog();
};
</script>

<template>
  <div class="flex-shrink-0">
    <button
      type="button"
      class="flex items-center justify-between gap-2 px-3 py-2 text-sm border rounded-lg border-n-weak dark:bg-n-solid-2 dark:hover:bg-n-solid-3 bg-n-alpha-2 hover:bg-n-alpha-1 min-w-[220px] max-w-full"
      @click="openDialog"
    >
      <span class="flex items-center min-w-0 gap-2">
        <Icon
          v-if="!selectedModelDetails"
          icon="i-lucide-bot"
          class="size-4 text-n-slate-11 flex-shrink-0"
        />
        <LobeProviderIcon
          v-else
          :provider-key="modelProviderKeyForModel(selectedModelDetails)"
          :title="modelProviderDisplayName(selectedModelDetails)"
          class="size-4 text-n-slate-11 flex-shrink-0"
        />
        <span
          v-if="selectedModelDetails"
          class="text-n-slate-12 truncate min-w-0"
        >
          {{ selectedModelDetails.display_name }}
        </span>
        <span v-else class="text-n-slate-10">
          {{ t('CAPTAIN_SETTINGS.MODEL_CONFIG.SELECT_MODEL') }}
        </span>
      </span>
      <Icon icon="i-lucide-search" class="size-4 text-n-slate-11" />
    </button>

    <Dialog
      ref="dialogRef"
      width="5xl"
      position="top"
      overflow-y-auto
      :title="
        t('CAPTAIN_SETTINGS.MODEL_CONFIG.MODEL_DIALOG_TITLE', {
          feature: featureTitle,
        })
      "
      :description="t('CAPTAIN_SETTINGS.MODEL_CONFIG.MODEL_DIALOG_DESCRIPTION')"
      :show-cancel-button="false"
      :show-confirm-button="false"
      @close="handleDialogClose"
    >
      <div class="flex min-h-[34rem] max-h-[78vh] flex-col gap-3">
        <label class="relative block">
          <input
            ref="searchInputRef"
            v-model="searchQuery"
            type="search"
            class="w-full h-10 px-3 text-sm border rounded-lg outline-none bg-n-alpha-2 border-n-weak text-n-slate-12 placeholder:text-n-slate-10 focus:border-n-brand [appearance:textfield] [&::-webkit-search-cancel-button]:appearance-none [&::-webkit-search-decoration]:appearance-none [&::-webkit-search-results-button]:appearance-none [&::-webkit-search-results-decoration]:appearance-none"
            :placeholder="
              t('CAPTAIN_SETTINGS.MODEL_CONFIG.MODEL_SEARCH_PLACEHOLDER')
            "
            :aria-label="
              t('CAPTAIN_SETTINGS.MODEL_CONFIG.MODEL_SEARCH_PLACEHOLDER')
            "
          />
        </label>

        <div
          v-if="filteredModels.length"
          class="flex flex-1 min-h-0 flex-col gap-6 pr-1 overflow-y-auto"
        >
          <section
            v-for="group in groupedFilteredModels"
            :key="group.key"
            class="flex min-w-0 flex-col gap-3"
          >
            <div
              class="flex items-center gap-2 px-1 pt-1 text-sm font-semibold text-n-slate-12"
            >
              <LobeProviderIcon
                :provider-key="group.key"
                :title="group.name"
                class="size-4 flex-shrink-0 text-n-slate-11"
              />
              <span>{{ group.name }}</span>
              <span class="text-xs font-medium text-n-slate-10">
                {{ group.models.length }}
              </span>
            </div>

            <button
              v-for="model in group.models"
              :key="model.id"
              type="button"
              class="flex w-full min-w-0 flex-col gap-2 p-2.5 text-left border rounded-lg border-n-weak bg-n-alpha-1 hover:bg-n-alpha-2 hover:border-n-strong transition-colors md:flex-row md:items-start"
              :class="{
                'border-n-brand bg-n-brand/5': selectedModelId === model.id,
                'opacity-60 cursor-not-allowed': model.coming_soon,
              }"
              :disabled="model.coming_soon"
              @click="selectModel(model)"
            >
              <div
                class="flex min-w-0 items-start gap-2 md:w-56 md:flex-shrink-0"
              >
                <div
                  class="flex items-center justify-center flex-shrink-0 border rounded-lg size-7 border-n-weak bg-n-solid-1"
                >
                  <LobeProviderIcon
                    :provider-key="modelProviderKeyForModel(model)"
                    :title="modelProviderDisplayName(model)"
                    class="size-3.5 text-n-slate-11"
                  />
                </div>

                <div class="flex min-w-0 flex-1 flex-col gap-1.5">
                  <div class="flex min-w-0 items-center gap-2">
                    <span
                      class="line-clamp-2 min-w-0 text-sm font-medium leading-5 text-n-slate-12"
                    >
                      {{ model.display_name }}
                    </span>
                    <Icon
                      v-if="selectedModelId === model.id"
                      icon="i-lucide-check"
                      class="size-4 text-n-brand flex-shrink-0"
                    />
                  </div>
                  <div class="flex min-w-0 flex-wrap items-center gap-1.5">
                    <span
                      v-if="hasSeparateModelProvider(model)"
                      class="inline-flex max-w-full items-center gap-1 rounded-md border border-n-weak bg-n-solid-1 px-1.5 py-0.5 text-[10px] leading-none text-n-slate-11"
                    >
                      <LobeProviderIcon
                        :provider-key="masterProviderKeyForModel(model)"
                        :title="masterProviderDisplayName(model)"
                        class="size-3 flex-shrink-0"
                      />
                      {{ providerRouteLabel(model) }}
                    </span>
                    <span
                      v-if="model.id === recommendedModelId"
                      class="text-[10px] uppercase text-n-iris-11 border border-n-iris-10 leading-none rounded-md px-1.5 py-0.5 flex-shrink-0"
                    >
                      {{ t('GENERAL.PREFERRED') }}
                    </span>
                    <span
                      v-if="model.coming_soon"
                      class="text-[10px] uppercase text-n-slate-11 border border-n-slate-5 leading-none rounded-md px-1.5 py-0.5 flex-shrink-0"
                    >
                      {{ t('CAPTAIN_SETTINGS.MODEL_CONFIG.COMING_SOON') }}
                    </span>
                  </div>
                  <span class="truncate text-[11px] leading-4 text-n-slate-10">
                    {{ model.id }}
                  </span>
                </div>
              </div>

              <div class="flex min-w-0 flex-1 flex-wrap gap-1.5">
                <div
                  v-for="item in metricItems(model)"
                  :key="`${model.id}-${item.label}`"
                  class="inline-flex max-w-full items-center gap-1 rounded-md border border-n-weak bg-white px-1.5 py-0.5 text-[11px] leading-4 dark:bg-n-solid-1"
                  :title="item.title || item.value"
                >
                  <Icon
                    :icon="item.icon"
                    class="size-3.5 flex-shrink-0 text-n-slate-10"
                  />
                  <span class="flex min-w-0 items-center gap-1">
                    <span class="whitespace-nowrap text-[10px] text-n-slate-10">
                      {{ item.label }}
                    </span>
                    <span
                      v-if="item.modalities?.length"
                      class="flex items-center gap-0.5 text-n-slate-12"
                    >
                      <Icon
                        v-for="modality in item.modalities"
                        :key="`${model.id}-${item.label}-${modality}`"
                        :icon="modalityIcon(modality)"
                        :title="modalityLabel(modality)"
                        class="size-3.5"
                      />
                    </span>
                    <span
                      v-else
                      class="truncate"
                      :class="
                        item.muted ? 'text-n-slate-10' : 'text-n-slate-12'
                      "
                    >
                      {{ item.value }}
                    </span>
                  </span>
                </div>
              </div>
            </button>
          </section>
        </div>

        <div
          v-else
          class="flex flex-1 min-h-[20rem] flex-col items-center justify-center gap-3 rounded-lg border border-dashed border-n-weak text-center"
        >
          <Icon icon="i-lucide-search-x" class="size-8 text-n-slate-10" />
          <p class="text-sm text-n-slate-11">
            {{ t('CAPTAIN_SETTINGS.MODEL_CONFIG.NO_MODELS_MATCH') }}
          </p>
        </div>
      </div>
    </Dialog>
  </div>
</template>
