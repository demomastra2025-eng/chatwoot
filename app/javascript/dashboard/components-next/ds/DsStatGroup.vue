<script setup>
// Key indicators: ONE card split by thin vertical dividers, never separate
// tiles. Caption above, big number, optional note below.
defineProps({
  items: {
    type: Array,
    required: true,
    validator: items => items.every(item => item.label !== undefined),
  },
});
</script>

<template>
  <dl
    class="m-0 grid grid-cols-2 overflow-hidden rounded-ds-card border border-solid border-n-weak bg-n-solid-2 md:grid-cols-[repeat(var(--ds-stat-columns),minmax(0,1fr))]"
    :style="{ '--ds-stat-columns': items.length }"
  >
    <div
      v-for="(item, index) in items"
      :key="item.key || index"
      class="min-w-0 border-0 border-solid border-n-weak px-5 py-[18px] md:border-e md:last:border-e-0 max-md:odd:border-e max-md:[&:nth-child(n+3)]:border-t"
      data-test-id="ds-stat"
    >
      <dt class="text-ds-caption text-n-slate-11">{{ item.label }}</dt>
      <dd class="m-0 mt-1.5 truncate text-ds-figure text-n-slate-12">
        <slot name="value" :item="item">{{ item.value }}</slot>
      </dd>
      <dd
        v-if="item.note || $slots.note"
        class="m-0 mt-1 text-ds-caption text-n-slate-11"
      >
        <slot name="note" :item="item">{{ item.note }}</slot>
      </dd>
    </div>
  </dl>
</template>
