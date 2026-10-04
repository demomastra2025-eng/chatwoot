<script setup>
import { computed } from 'vue';
import { useI18n } from 'vue-i18n';

// A status is ALWAYS a dot plus a word, never colour alone. When no label is
// passed the default word for the status is shown.
const props = defineProps({
  status: {
    type: String,
    default: 'neutral',
    validator: value => ['good', 'warn', 'bad', 'neutral'].includes(value),
  },
  label: { type: String, default: '' },
});

const { t } = useI18n();

const DOT_CLASSES = {
  good: 'bg-n-status-good',
  warn: 'bg-n-status-warn',
  bad: 'bg-n-status-bad',
  neutral: 'bg-n-slate-9',
};

const word = computed(() => {
  if (props.label) return props.label;
  return {
    good: t('DESIGN_SYSTEM.STATUS.GOOD'),
    warn: t('DESIGN_SYSTEM.STATUS.WARN'),
    bad: t('DESIGN_SYSTEM.STATUS.BAD'),
    neutral: t('DESIGN_SYSTEM.STATUS.NEUTRAL'),
  }[props.status];
});
</script>

<template>
  <span
    class="inline-flex items-center gap-1.5 whitespace-nowrap text-ds-caption text-n-slate-12"
    :data-status="status"
  >
    <span
      class="inline-block size-[7px] flex-shrink-0 rounded-full"
      :class="DOT_CLASSES[status]"
      aria-hidden="true"
      data-test-id="ds-status-dot"
    />
    <span>{{ word }}</span>
  </span>
</template>
