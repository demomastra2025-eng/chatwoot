<script setup>
import { computed } from 'vue';
import { useI18n } from 'vue-i18n';

import { resolveCustomFieldEntries } from 'dashboard/stores/crm/customFieldFormatter';

const props = defineProps({
  definitions: {
    type: Array,
    default: () => [],
  },
  maxItems: {
    type: Number,
    default: 2,
  },
  truncate: {
    type: Boolean,
    default: true,
  },
  values: {
    type: Object,
    default: () => ({}),
  },
});

const { locale, t } = useI18n();

const localeCode = computed(
  () => locale.value?.replace(/_/g, '-') || undefined
);

const allEntries = computed(() =>
  resolveCustomFieldEntries(props.definitions, props.values, {
    locale: localeCode.value,
    noLabel: t('CHOICE_TOGGLE.NO'),
    yesLabel: t('CHOICE_TOGGLE.YES'),
  })
);

const visibleEntries = computed(() =>
  allEntries.value.slice(0, props.maxItems)
);
const overflowCount = computed(() =>
  Math.max(allEntries.value.length - visibleEntries.value.length, 0)
);
</script>

<template>
  <div v-show="visibleEntries.length" class="grid gap-1">
    <div
      v-for="entry in visibleEntries"
      :key="entry.key"
      class="text-[11px] text-n-slate-11"
      :class="truncate ? 'truncate' : 'whitespace-normal break-words text-wrap'"
      :title="`${entry.label}: ${entry.displayValue}`"
    >
      <span class="font-medium text-n-slate-12">{{ `${entry.label}:` }}</span>
      <span class="ml-1">{{ entry.displayValue }}</span>
    </div>

    <div
      v-if="overflowCount"
      class="text-[11px] font-medium text-n-slate-11"
      :title="`+${overflowCount}`"
    >
      {{ `+${overflowCount}` }}
    </div>
  </div>
</template>
