<script setup>
defineProps({
  columns: {
    type: Array,
    required: true,
  },
  rows: {
    type: Array,
    default: () => [],
  },
});
</script>

<template>
  <div class="overflow-hidden border rounded-2xl border-n-weak">
    <div
      class="grid px-4 py-3 text-xs font-semibold uppercase border-b bg-n-surface-2 border-n-weak text-n-slate-10"
      :style="{
        gridTemplateColumns: columns
          .map(column => column.width || '1fr')
          .join(' '),
      }"
    >
      <div
        v-for="column in columns"
        :key="column.key"
        :class="column.align === 'end' ? 'text-end' : 'text-start'"
      >
        {{ column.label }}
      </div>
    </div>

    <div
      v-if="rows.length === 0"
      class="px-4 py-8 text-sm text-center text-n-slate-11"
    >
      <slot name="empty">
        {{ $t('SCHEDULING.GENERAL.NO_DATA') }}
      </slot>
    </div>

    <div v-else class="divide-y divide-n-weak">
      <div
        v-for="row in rows"
        :key="row.id"
        class="grid items-center gap-3 px-4 py-3 text-sm text-n-slate-12"
        :style="{
          gridTemplateColumns: columns
            .map(column => column.width || '1fr')
            .join(' '),
        }"
      >
        <div
          v-for="column in columns"
          :key="column.key"
          :class="column.align === 'end' ? 'text-end' : 'text-start'"
        >
          <slot :name="`cell-${column.key}`" :row="row">
            {{ row[column.key] }}
          </slot>
        </div>
      </div>
    </div>
  </div>
</template>
