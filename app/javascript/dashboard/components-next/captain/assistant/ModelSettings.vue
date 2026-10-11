<script setup>
import { computed, watch } from 'vue';
import { useI18n } from 'vue-i18n';
import Select from 'dashboard/components-next/select/Select.vue';

const props = defineProps({
  model: { type: String, default: '' },
  temperature: { type: Number, default: null },
  effort: { type: String, default: '' },
  metadata: { type: Object, default: () => ({}) },
  models: { type: Array, default: () => [] },
  disabled: { type: Boolean, default: false },
  defaultLabel: { type: String, default: '' },
  // One column (narrow side blocks, e.g. the agent page «Модель» block).
  stacked: { type: Boolean, default: false },
  // Label of the model select; empty keeps the playground wording.
  modelLabel: { type: String, default: '' },
});
const emit = defineEmits([
  'update:model',
  'update:temperature',
  'update:effort',
]);
const { t } = useI18n();
const supportsTemperature = computed(
  () => props.metadata?.supports_temperature === true
);
const efforts = computed(() => props.metadata?.reasoning_efforts || []);
const effortOptions = computed(() => [
  {
    value: '',
    label: props.defaultLabel || t('CAPTAIN.MODEL_SETTINGS.PROVIDER_DEFAULT'),
  },
  ...efforts.value.map(value => ({
    value,
    label: t(`CAPTAIN.PLAYGROUND.REASONING_${value.toUpperCase()}`),
  })),
]);
watch(
  () => props.metadata?.supports_temperature,
  supported => {
    if (supported === false && props.temperature !== null)
      emit('update:temperature', null);
  }
);
watch(efforts, supported => {
  if (
    Array.isArray(props.metadata?.reasoning_efforts) &&
    props.effort &&
    !supported.includes(props.effort)
  )
    emit('update:effort', '');
});
</script>

<template>
  <div class="min-w-0" data-test="model-settings">
    <div
      class="grid gap-4"
      :class="stacked ? 'grid-cols-1' : 'md:grid-cols-3'"
      data-test="model-settings-grid"
    >
      <label class="flex min-w-0 flex-col gap-1 text-xs text-n-slate-11">
        {{ modelLabel || t('CAPTAIN.PLAYGROUND.TEST_MODEL') }}
        <Select
          class="w-full min-w-0"
          :model-value="model"
          :options="models"
          :disabled="disabled"
          @update:model-value="emit('update:model', $event)"
        />
      </label>
      <div
        v-if="supportsTemperature"
        class="flex min-w-0 flex-col gap-2"
        data-test="model-temperature"
      >
        <label class="flex items-center gap-2 text-xs text-n-slate-11">
          <input
            type="checkbox"
            :checked="temperature !== null"
            :disabled="disabled"
            @change="
              emit('update:temperature', $event.target.checked ? 1 : null)
            "
          />
          {{ t('CAPTAIN.PLAYGROUND.TEST_TEMPERATURE') }}
        </label>
        <div v-if="temperature !== null" class="flex items-center gap-3">
          <input
            type="range"
            min="0"
            max="1"
            step="0.1"
            :value="temperature"
            :disabled="disabled"
            class="min-w-0 flex-1 accent-n-brand"
            @input="emit('update:temperature', Number($event.target.value))"
          />
          <span class="text-xs tabular-nums text-n-slate-11">{{
            Number(temperature).toFixed(1)
          }}</span>
        </div>
        <span v-else class="text-xs text-n-slate-10">{{
          defaultLabel || t('CAPTAIN.MODEL_SETTINGS.PROVIDER_DEFAULT')
        }}</span>
      </div>
      <label
        v-if="efforts.length"
        class="flex min-w-0 flex-col gap-1 text-xs text-n-slate-11"
        data-test="model-reasoning"
      >
        {{ t('CAPTAIN.PLAYGROUND.TEST_REASONING_EFFORT') }}
        <Select
          class="w-full min-w-0"
          :model-value="effort"
          :options="effortOptions"
          :disabled="disabled"
          @update:model-value="emit('update:effort', $event)"
        />
      </label>
    </div>
  </div>
</template>
