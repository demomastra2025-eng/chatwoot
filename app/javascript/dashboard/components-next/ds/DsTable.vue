<script setup>
import { useI18n } from 'vue-i18n';
import DsState from './DsState.vue';

// Plain data table: thin row lines, muted header, numeric columns aligned to
// the end with tabular figures. Cells can be replaced via `cell-<key>` slots.
defineProps({
  columns: {
    type: Array,
    required: true,
    validator: columns => columns.every(column => column.key && column.label),
  },
  rows: { type: Array, default: () => [] },
  rowKey: { type: [String, Function], default: 'id' },
  caption: { type: String, default: '' },
  emptyText: { type: String, default: '' },
});

const { t } = useI18n();

const keyFor = (row, index, rowKey) => {
  if (typeof rowKey === 'function') return rowKey(row);
  return row[rowKey] ?? index;
};

const alignClass = column =>
  column.numeric || column.align === 'end' ? 'text-end' : 'text-start';
</script>

<template>
  <div class="w-full overflow-x-auto">
    <table class="w-full border-collapse text-sm text-n-slate-12">
      <caption v-if="caption" class="sr-only">
        {{
          caption
        }}
      </caption>
      <thead>
        <tr>
          <th
            v-for="column in columns"
            :key="column.key"
            scope="col"
            class="whitespace-nowrap border-0 border-b border-solid border-n-weak px-3 py-2 text-xs font-medium text-n-slate-11 first:ps-5 last:pe-5"
            :class="alignClass(column)"
          >
            {{ column.label }}
          </th>
        </tr>
      </thead>
      <tbody v-if="rows.length">
        <tr
          v-for="(row, index) in rows"
          :key="keyFor(row, index, rowKey)"
          class="[&:last-child>td]:border-b-0"
        >
          <td
            v-for="column in columns"
            :key="column.key"
            class="border-0 border-b border-solid border-n-weak px-3 py-[11px] align-middle first:ps-5 last:pe-5"
            :class="[alignClass(column), { 'tabular-nums': column.numeric }]"
          >
            <slot
              :name="`cell-${column.key}`"
              :row="row"
              :value="row[column.key]"
            >
              {{ row[column.key] }}
            </slot>
          </td>
        </tr>
      </tbody>
    </table>
    <DsState
      v-if="!rows.length"
      state="empty"
      compact
      :title="emptyText || t('DESIGN_SYSTEM.TABLE.EMPTY')"
      description=""
    />
  </div>
</template>
