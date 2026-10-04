<script setup>
import { computed } from 'vue';
import { useI18n } from 'vue-i18n';

// 4px meter. The fill carries severity (accent -> warn -> bad); the track is
// a light step of the same hue so the state reads across the whole bar.
const props = defineProps({
  value: { type: Number, required: true },
  max: { type: Number, default: 100 },
  // 'auto' switches to warn at warnAt and to bad at badAt (percent)
  tone: {
    type: String,
    default: 'accent',
    validator: value => ['accent', 'warn', 'bad', 'auto'].includes(value),
  },
  warnAt: { type: Number, default: 80 },
  badAt: { type: Number, default: 95 },
  showValue: { type: Boolean, default: true },
  label: { type: String, default: '' },
});

const { t } = useI18n();

const percent = computed(() => {
  if (!props.max) return 0;
  const raw = (props.value / props.max) * 100;
  return Math.min(100, Math.max(0, Math.round(raw)));
});

const resolvedTone = computed(() => {
  if (props.tone !== 'auto') return props.tone;
  if (percent.value >= props.badAt) return 'bad';
  if (percent.value >= props.warnAt) return 'warn';
  return 'accent';
});

const TONE_CLASSES = {
  accent: { track: 'bg-n-brand/15', fill: 'bg-n-brand' },
  warn: { track: 'bg-n-status-warn/15', fill: 'bg-n-status-warn' },
  bad: { track: 'bg-n-status-bad/15', fill: 'bg-n-status-bad' },
};

const valueText = computed(() =>
  t('DESIGN_SYSTEM.METER.VALUE', { value: percent.value })
);
</script>

<template>
  <div class="flex min-w-0 items-center gap-2" :data-tone="resolvedTone">
    <div
      role="meter"
      :aria-label="label || undefined"
      aria-valuemin="0"
      aria-valuemax="100"
      :aria-valuenow="percent"
      :aria-valuetext="valueText"
      class="h-1 min-w-12 flex-1 overflow-hidden rounded-full"
      :class="TONE_CLASSES[resolvedTone].track"
    >
      <div
        class="h-full rounded-full"
        :class="TONE_CLASSES[resolvedTone].fill"
        :style="{ width: `${percent}%` }"
        data-test-id="ds-meter-fill"
      />
    </div>
    <span
      v-if="showValue"
      class="flex-shrink-0 text-ds-caption tabular-nums text-n-slate-12"
    >
      {{ valueText }}
    </span>
  </div>
</template>
