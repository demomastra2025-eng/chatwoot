<script setup>
defineProps({
  chips: {
    type: Array,
    default: () => [],
  },
});

const emit = defineEmits(['remove', 'reset']);
</script>

<template>
  <div
    class="flex flex-wrap items-center gap-2 px-5 pt-2"
    data-test="active-deal-filters"
  >
    <button
      v-for="chip in chips"
      :key="chip.key"
      type="button"
      class="inline-flex max-w-64 items-center gap-1 rounded-full bg-n-brand/10 px-2.5 py-1 text-xs text-n-brand"
      :aria-label="`${$t('CRM.FILTERS.REMOVE')}: ${chip.label}`"
      @click="emit('remove', chip.key)"
    >
      <span class="truncate">{{ chip.label }}</span>
      <i class="i-lucide-x shrink-0" aria-hidden="true" />
    </button>
    <button
      type="button"
      class="text-xs font-medium text-n-slate-11 hover:text-n-slate-12"
      data-test="reset-deal-filters"
      @click="emit('reset')"
    >
      {{ $t('CRM.FILTERS.RESET_SHORT') }}
    </button>
  </div>
</template>
