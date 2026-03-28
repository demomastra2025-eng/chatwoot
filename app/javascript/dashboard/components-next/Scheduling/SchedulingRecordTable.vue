<script setup>
const props = defineProps({
  borderless: {
    type: Boolean,
    default: false,
  },
  columns: {
    type: Array,
    required: true,
  },
  rows: {
    type: Array,
    default: () => [],
  },
  rowClass: {
    type: [Function, String],
    default: '',
  },
});
</script>

<template>
  <div
    class="overflow-hidden rounded-2xl bg-n-solid-2"
    :class="
      props.borderless ? '' : 'outline outline-1 outline-n-container shadow-sm'
    "
  >
    <div
      class="grid border-b border-n-weak bg-n-surface-2/80 px-5 py-3 text-[11px] font-semibold uppercase tracking-[0.08em] text-n-slate-10 backdrop-blur"
      :style="{
        gridTemplateColumns: columns
          .map(column => column.width || '1fr')
          .join(' '),
      }"
    >
      <div
        v-for="column in columns"
        :key="column.key"
        class="min-w-0 truncate"
        :title="column.label"
        :class="[column.align === 'end' ? 'text-end' : 'text-start']"
      >
        {{ column.label }}
      </div>
    </div>

    <div
      v-if="rows.length === 0"
      class="px-5 py-10 text-sm text-center text-n-slate-11"
    >
      <slot name="empty">
        {{ $t('SCHEDULING.GENERAL.NO_DATA') }}
      </slot>
    </div>

    <div v-else class="divide-y divide-n-weak">
      <div
        v-for="row in rows"
        :key="row.id"
        class="grid items-center gap-3 px-5 py-3 text-sm text-n-slate-12 transition-colors hover:bg-n-alpha-1"
        :class="
          typeof props.rowClass === 'function'
            ? props.rowClass(row)
            : props.rowClass
        "
        :style="{
          gridTemplateColumns: columns
            .map(column => column.width || '1fr')
            .join(' '),
        }"
      >
        <div
          v-for="column in columns"
          :key="column.key"
          class="min-w-0"
          :class="[column.align === 'end' ? 'text-end' : 'text-start']"
        >
          <slot :name="`cell-${column.key}`" :row="row">
            {{ row[column.key] }}
          </slot>
        </div>
      </div>
    </div>
  </div>
</template>
