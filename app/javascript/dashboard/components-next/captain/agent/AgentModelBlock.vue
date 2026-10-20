<script setup>
import { computed } from 'vue';
import { useI18n } from 'vue-i18n';
import Icon from 'dashboard/components-next/icon/Icon.vue';
import ModelSettings from 'dashboard/components-next/captain/assistant/ModelSettings.vue';
import { useCaptainConfigStore } from 'dashboard/store/captain/preferences';
import {
  findAgentModelMetadata,
  resolveDefaultAgentEffort,
  resolveModelIcon,
} from './agentDraft';

// «Модель» block of the agent page side column: the model from the platform
// allowlist and only the parameters that model supports.
const props = defineProps({
  model: { type: String, default: '' },
  temperature: { type: Number, default: null },
  effort: { type: String, default: '' },
  assistant: { type: Object, default: () => ({}) },
  disabled: { type: Boolean, default: false },
});

const emit = defineEmits([
  'update:model',
  'update:temperature',
  'update:effort',
]);

const { t } = useI18n();
const captainConfigStore = useCaptainConfigStore();

const clientModelLabel = label =>
  String(label || '').replace(
    /openrouter/gi,
    t('CAPTAIN.AGENT_PAGE.MODEL.PROVIDER_WORD')
  );

const catalogModels = computed(
  () => captainConfigStore.getModelsForFeature('assistant') || []
);
const platformModelId = computed(
  () => captainConfigStore.getSelectedModelForFeature('assistant') || ''
);

// The select shows the model that really answers; choosing the platform
// default stores '' so the agent follows future platform changes.
const selectedModelValue = computed({
  get: () => props.model || platformModelId.value,
  set: value => {
    emit('update:model', value === platformModelId.value ? '' : value || '');
  },
});

const markedLabel = (name, markKey) => `${name} (${t(markKey)})`;

const modelOptions = computed(() => {
  const options = catalogModels.value
    .filter(
      model =>
        !model.current_only ||
        model.id === props.model ||
        model.id === platformModelId.value
    )
    .map(model => {
      const name = clientModelLabel(model.display_name || model.id);
      const label = model.current_only
        ? markedLabel(name, 'CAPTAIN.AGENT_PAGE.MODEL.CURRENT_MARK')
        : name;
      return {
        value: model.id,
        label,
        ...resolveModelIcon(model),
      };
    });

  // A saved model outside today's allowlist stays visible and selected.
  if (props.model && !options.some(option => option.value === props.model)) {
    const savedName =
      props.assistant?.playground_model?.id === props.model
        ? props.assistant.playground_model.display_name
        : '';
    options.unshift({
      value: props.model,
      label: markedLabel(
        clientModelLabel(savedName || props.model),
        'CAPTAIN.AGENT_PAGE.MODEL.CURRENT_MARK'
      ),
      ...resolveModelIcon({ id: props.model, display_name: savedName }),
    });
  }

  if (
    platformModelId.value &&
    !options.some(option => option.value === platformModelId.value)
  ) {
    options.unshift({
      value: platformModelId.value,
      label: clientModelLabel(platformModelId.value),
      ...resolveModelIcon(platformModelId.value),
    });
  }

  return options;
});

const metadata = computed(() =>
  findAgentModelMetadata({
    models: catalogModels.value,
    modelId: props.model || platformModelId.value,
    assistant: props.assistant,
  })
);

const selectedEffortValue = computed(() => {
  const supported = Array.isArray(metadata.value?.reasoning_efforts)
    ? metadata.value.reasoning_efforts
    : [];
  if (props.effort && supported.includes(props.effort)) return props.effort;
  return resolveDefaultAgentEffort(metadata.value);
});

// Without access to the catalog (non-admins) only the name is shown.
const readOnlyModelName = computed(() => {
  const playgroundModel = props.assistant?.playground_model;
  if (playgroundModel?.display_name) {
    return clientModelLabel(playgroundModel.display_name);
  }
  if (props.model) return clientModelLabel(props.model);
  return t('CAPTAIN.AGENT_PAGE.MODEL.PLATFORM_DEFAULT');
});

const readOnlyModelIcon = computed(() =>
  resolveModelIcon(
    props.assistant?.playground_model || props.model || platformModelId.value
  )
);
</script>

<template>
  <section
    class="flex flex-col outline outline-1 -outline-offset-1 outline-n-weak rounded-xl bg-n-solid-2 divide-y divide-n-weak"
    data-test="agent-model-block"
  >
    <div class="px-5 py-4">
      <h3 class="mb-0 text-heading-2 text-n-slate-12">
        {{ t('CAPTAIN.AGENT_PAGE.MODEL.TITLE') }}
      </h3>
    </div>
    <div class="grid gap-5 px-5 py-4">
      <ModelSettings
        v-if="modelOptions.length"
        v-model:model="selectedModelValue"
        :temperature="temperature"
        :effort="selectedEffortValue"
        :metadata="metadata"
        :models="modelOptions"
        :disabled="disabled"
        :default-label="t('CAPTAIN.AGENT_PAGE.MODEL.DEFAULT_OPTION')"
        :model-label="t('CAPTAIN.AGENT_PAGE.MODEL.SELECT_LABEL')"
        hide-default-effort
        stacked
        @update:temperature="emit('update:temperature', $event)"
        @update:effort="emit('update:effort', $event)"
      />
      <p
        v-else
        class="mb-0 flex items-center gap-2 text-body-main text-n-slate-12"
        data-test="agent-model-name"
      >
        <Icon
          v-if="readOnlyModelIcon.icon"
          :icon="readOnlyModelIcon.icon"
          class="size-4 shrink-0"
          :class="readOnlyModelIcon.iconClass || 'text-n-slate-12'"
        />
        <span>{{ readOnlyModelName }}</span>
      </p>
    </div>
  </section>
</template>
