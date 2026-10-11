<script setup>
import { computed } from 'vue';
import { useI18n } from 'vue-i18n';
import SettingsToggleSection from 'dashboard/components-next/Settings/SettingsToggleSection.vue';
import RadioCard from 'dashboard/components-next/radioCard/RadioCard.vue';
import TextArea from 'dashboard/components-next/textarea/TextArea.vue';
import {
  MESSAGE_MODES,
  statusMessageNeedsText,
} from 'dashboard/helper/captainAiSettings';

// A message sent to the customer on handoff or on resolution:
// { enabled, mode: 'fixed' | 'generated', text }. The text is required for a
// fixed message and is an optional hint for a generated one.
const props = defineProps({
  kind: { type: String, required: true },
  title: { type: String, required: true },
  description: { type: String, default: '' },
  showErrors: { type: Boolean, default: false },
  error: { type: String, default: '' },
  disabled: { type: Boolean, default: false },
});

const model = defineModel({ type: Object, required: true });

const { t } = useI18n();

const MAX_TEXT_LENGTH = 2000;

const update = changes => {
  model.value = { ...model.value, ...changes };
};

const enabled = computed({
  get: () => model.value?.enabled === true,
  set: value => update({ enabled: value }),
});

const isFixed = computed(() => model.value?.mode !== 'generated');

const modeOptions = computed(() =>
  MESSAGE_MODES.map(mode => {
    const key = `CAPTAIN.AI_SETTINGS.HANDOFF.MODE_${mode.toUpperCase()}`;
    return {
      id: `${props.kind}-message-${mode}`,
      mode,
      label: t(key),
      description: t(`${key}_DESCRIPTION`),
    };
  })
);

const selectMode = mode => {
  if (props.disabled || model.value?.mode === mode) return;
  update({ mode });
};

const textError = computed(() => {
  if (props.showErrors && statusMessageNeedsText(model.value)) {
    return t('CAPTAIN.AI_SETTINGS.HANDOFF.TEXT_REQUIRED');
  }
  return props.error;
});
</script>

<template>
  <SettingsToggleSection
    v-model="enabled"
    :header="title"
    :description="description"
    :disabled="disabled"
    :data-testid="`status-message-${kind}`"
  >
    <template v-if="enabled" #editor>
      <div class="flex flex-col gap-4">
        <div
          class="grid gap-3 sm:grid-cols-2"
          role="radiogroup"
          :aria-label="title"
        >
          <RadioCard
            v-for="option in modeOptions"
            :id="option.id"
            :key="option.id"
            :label="option.label"
            :description="option.description"
            :is-active="(model.mode || 'fixed') === option.mode"
            :data-testid="option.id"
            @select="selectMode(option.mode)"
          />
        </div>
        <TextArea
          :id="`${kind}-message-text`"
          :model-value="model.text || ''"
          :label="
            isFixed
              ? t('CAPTAIN.AI_SETTINGS.HANDOFF.TEXT_LABEL_FIXED')
              : t('CAPTAIN.AI_SETTINGS.HANDOFF.TEXT_LABEL_GENERATED')
          "
          :placeholder="
            isFixed
              ? t('CAPTAIN.AI_SETTINGS.HANDOFF.TEXT_PLACEHOLDER_FIXED')
              : t('CAPTAIN.AI_SETTINGS.HANDOFF.TEXT_PLACEHOLDER_GENERATED')
          "
          :max-length="MAX_TEXT_LENGTH"
          :disabled="disabled"
          :message="textError"
          :message-type="textError ? 'error' : 'info'"
          auto-height
          @update:model-value="update({ text: $event })"
        />
      </div>
    </template>
  </SettingsToggleSection>
</template>
