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
  sortState: {
    type: Object,
    default: () => ({
      direction: '',
      key: '',
    }),
  },
});

const emit = defineEmits(['sort']);

const resolveSortDirection = columnKey => {
  return props.sortState?.key === columnKey ? props.sortState?.direction : '';
};

const resolveSortIcon = columnKey => {
  const direction = resolveSortDirection(columnKey);

  if (direction === 'asc') return 'i-lucide-chevron-up';
  if (direction === 'desc') return 'i-lucide-chevron-down';
  return 'i-lucide-arrow-up-down';
};

const resolveNextSortDirection = column => {
  const currentDirection = resolveSortDirection(column.key);

  if (currentDirection === 'asc') {
    return 'desc';
  }

  if (currentDirection === 'desc') {
    return 'asc';
  }

  return column.defaultSortDirection || 'asc';
};

const handleHeaderSort = column => {
  if (!column.sortable) return;

  emit('sort', {
    direction: resolveNextSortDirection(column),
    key: column.key,
  });
};
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
        :class="[
          column.align === 'end' ? 'text-end' : 'text-start',
          column.headerClass,
        ]"
      >
        <slot :name="`header-${column.key}`" :column="column">
          <button
            v-if="column.sortable"
            type="button"
            class="inline-flex w-full items-center gap-1 border-0 bg-transparent p-0 text-inherit"
            :class="[
              column.align === 'end' ? 'justify-end' : 'justify-start',
              resolveSortDirection(column.key)
                ? 'text-n-slate-12'
                : 'text-inherit',
            ]"
            @click="handleHeaderSort(column)"
          >
            <span class="truncate">{{ column.label }}</span>
            <span
              class="size-3.5 shrink-0 transition-opacity"
              :class="[
                resolveSortIcon(column.key),
                resolveSortDirection(column.key) ? 'opacity-100' : 'opacity-55',
              ]"
              aria-hidden="true"
            />
          </button>
          <span v-else>
            {{ column.label }}
          </span>
        </slot>
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
          :class="[
            column.align === 'end' ? 'text-end' : 'text-start',
            column.cellClass,
          ]"
        >
          <slot :name="`cell-${column.key}`" :row="row">
            {{ row[column.key] }}
          </slot>
        </div>
      </div>
    </div>
  </div>
</template>
