<script setup>
import { computed, ref, watch } from 'vue';
import { useI18n } from 'vue-i18n';
import Draggable from 'vuedraggable';

import CrmCustomFieldsSummary from './CrmCustomFieldsSummary.vue';
import { buildTaskTypeResolver } from './taskTypeMetadata';
import {
  groupTasksByTime,
  taskDueDate,
  visibleTaskTimeBuckets,
} from 'dashboard/routes/dashboard/crm/taskTimeBuckets';

const props = defineProps({
  taskTypeResolver: {
    type: Function,
    default: null,
  },
  assignees: {
    type: Array,
    default: () => [],
  },
  canManage: {
    type: Boolean,
    default: false,
  },
  dealNames: {
    type: Object,
    default: () => ({}),
  },
  fieldDefinitions: {
    type: Array,
    default: () => [],
  },
  tasks: {
    type: Array,
    default: () => [],
  },
});

const emit = defineEmits(['changeDueDate', 'selectTask']);
const { locale, t } = useI18n();
const assigneeNameById = computed(() =>
  props.assignees.reduce((result, assignee) => {
    result[Number(assignee.value)] = assignee.label;
    return result;
  }, {})
);

const localeCode = computed(
  () => locale.value?.replace(/_/g, '-') || undefined
);
const groupedTasks = ref(groupTasksByTime(props.tasks));
const visibleBucketKeys = ref(visibleTaskTimeBuckets(groupedTasks.value));

watch(
  () => props.tasks,
  tasks => {
    groupedTasks.value = groupTasksByTime(tasks);
    visibleBucketKeys.value = visibleTaskTimeBuckets(groupedTasks.value);
  },
  { deep: true }
);

const bucketMeta = computed(() => ({
  future: {
    color: '#E7E8EA',
    label: t('CRM.TASKS.BOARD.TIME_BUCKETS.FUTURE'),
  },
  nextWeek: {
    color: '#E7E8EA',
    label: t('CRM.TASKS.BOARD.TIME_BUCKETS.NEXT_WEEK'),
  },
  overdue: {
    color: '#FF8F93',
    label: t('CRM.TASKS.BOARD.TIME_BUCKETS.OVERDUE'),
  },
  today: {
    color: '#87F1C0',
    label: t('CRM.TASKS.BOARD.TIME_BUCKETS.TODAY'),
  },
  tomorrow: {
    color: '#E7E8EA',
    label: t('CRM.TASKS.BOARD.TIME_BUCKETS.TOMORROW'),
  },
  thisMonth: {
    color: '#E7E8EA',
    label: t('CRM.TASKS.BOARD.TIME_BUCKETS.THIS_MONTH'),
  },
  unscheduled: {
    color: '#F2F3F5',
    label: t('CRM.TASKS.BOARD.TIME_BUCKETS.UNSCHEDULED'),
  },
}));

const boardColumns = computed(() =>
  visibleBucketKeys.value.map(key => ({
    ...bucketMeta.value[key],
    key,
    tasks: groupedTasks.value[key],
  }))
);

const handleColumnChange = (event, bucket) => {
  if (!event.added || !props.canManage) return;

  const task = groupedTasks.value[bucket][event.added.newIndex];
  emit('changeDueDate', { bucket, task });
};

const fallbackTaskTypeResolver = computed(() => buildTaskTypeResolver([], t));

const formatDateLabel = task => {
  const value = taskDueDate(task);
  if (!value) return t('CRM.TASKS.BOARD.TIME_BUCKETS.UNSCHEDULED');

  const options = {
    day: 'numeric',
    month: 'short',
  };
  if (!task.allDay) {
    options.hour = '2-digit';
    options.minute = '2-digit';
  }

  return new Intl.DateTimeFormat(localeCode.value, options).format(value);
};

const activityTypeMeta = task =>
  (props.taskTypeResolver || fallbackTaskTypeResolver.value)(task);
</script>

<template>
  <div class="flex h-full min-h-0 flex-col overflow-auto px-1 pb-2">
    <div class="mx-auto flex w-max min-h-full items-stretch gap-0 py-1">
      <section
        v-for="column in boardColumns"
        :key="column.key"
        class="crm-task-board-column flex min-h-full w-[18rem] shrink-0 self-stretch flex-col overflow-visible"
      >
        <header
          class="sticky top-0 z-10 bg-n-slate-2/95 px-3 pt-3 pb-1.5 backdrop-blur supports-[backdrop-filter]:bg-n-slate-2/80"
        >
          <div class="flex items-center justify-between gap-3">
            <h3 class="mb-0 truncate text-sm font-semibold text-n-slate-12">
              {{ column.label }}
            </h3>
            <span
              class="rounded-full bg-n-alpha-black2 px-2 py-0.5 text-xs font-medium text-n-slate-11"
            >
              {{ column.tasks.length }}
            </span>
          </div>
          <div
            class="crm-task-board-bucket-color mt-3 h-1 overflow-hidden rounded-full"
            :style="{ backgroundColor: column.color }"
          />
        </header>

        <Draggable
          :list="groupedTasks[column.key]"
          :disabled="!canManage"
          animation="180"
          class="flex min-h-[5rem] flex-col gap-3 px-3 pb-3 pt-1.5"
          ghost-class="crm-task-board-card-ghost"
          group="crm-task-time-buckets"
          item-key="id"
          @change="handleColumnChange($event, column.key)"
        >
          <template #item="{ element: task }">
            <article
              class="cursor-grab rounded-md border border-n-weak bg-n-surface-1 px-2.5 py-2 shadow-sm transition-shadow hover:shadow-md active:cursor-grabbing"
              @click="emit('selectTask', task)"
            >
              <div class="flex items-start justify-between gap-2">
                <button
                  type="button"
                  data-test="open-task"
                  class="min-w-0 text-left focus-visible:rounded focus-visible:outline focus-visible:outline-2 focus-visible:outline-offset-2 focus-visible:outline-n-brand"
                >
                  <h4
                    class="mb-0 truncate text-xs font-semibold text-n-slate-12"
                  >
                    {{ task.title }}
                  </h4>
                  <p
                    v-if="dealNames[task.dealId]"
                    class="mb-0 mt-0.5 text-[10px] text-n-slate-11"
                  >
                    {{ dealNames[task.dealId] }}
                  </p>
                </button>

                <span
                  class="max-w-[8.5rem] truncate rounded-md bg-n-alpha-black2 px-1.5 py-1 text-[9px] font-medium text-n-slate-12"
                >
                  {{
                    assigneeNameById[task.assigneeId] ||
                    $t('CRM.GENERAL.EMPTY_VALUE')
                  }}
                </span>
              </div>

              <div class="mt-2 flex items-center justify-between gap-2">
                <span
                  class="inline-flex items-center gap-1 rounded-full border border-n-weak bg-n-surface-1 px-2 py-0.5 text-[10px] font-medium text-n-slate-11"
                >
                  <span
                    class="size-3"
                    :class="activityTypeMeta(task).icon"
                    aria-hidden="true"
                  />
                  {{ activityTypeMeta(task).label }}
                </span>
                <span
                  v-if="column.key === 'overdue'"
                  class="rounded-full bg-n-ruby-9/10 px-2 py-0.5 text-[10px] font-semibold text-n-ruby-11"
                >
                  {{ $t('CRM.TASKS.BOARD.OVERDUE_BADGE') }}
                </span>
                <span v-else class="text-[9px] text-n-slate-10/90">
                  {{ formatDateLabel(task) }}
                </span>
              </div>

              <CrmCustomFieldsSummary
                class="mt-2"
                :definitions="fieldDefinitions"
                :values="task.customAttributes"
              />
            </article>
          </template>
        </Draggable>
      </section>
    </div>
  </div>
</template>
