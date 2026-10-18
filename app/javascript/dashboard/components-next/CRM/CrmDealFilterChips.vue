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
    class="flex flex-wrap items-center gap-1"
    data-test="active-deal-filters"
  >
    <button
      v-for="chip in chips"
      :key="chip.key"
      type="button"
      class="inline-flex max-w-56 items-center gap-1 rounded-md bg-n-brand/10 px-2 py-0.5 text-xs font-medium text-n-brand hover:bg-n-brand/15"
      :aria-label="`${$t('CRM.FILTERS.REMOVE')}: ${chip.label}`"
      @click.stop="emit('remove', chip.key)"
    >
      <span class="truncate">{{ chip.label }}</span>
      <i class="i-lucide-x size-3 shrink-0" aria-hidden="true" />
    </button>
    <button
      type="button"
      class="px-1 py-0.5 text-xs font-medium text-n-slate-11 hover:text-n-slate-12"
      data-test="reset-deal-filters"
      @click.stop="emit('reset')"
    >
      {{ $t('CRM.FILTERS.RESET_SHORT') }}
    </button>
  </div>
</template>
