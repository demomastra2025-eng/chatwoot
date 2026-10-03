<script setup>
import { computed, onMounted, onUnmounted, ref } from 'vue';
import { useI18n } from 'vue-i18n';

import CrmCustomFieldsSummary from './CrmCustomFieldsSummary.vue';
import CrmTaskAssigneeMenu from './CrmTaskAssigneeMenu.vue';
import { sortListRecords } from 'dashboard/routes/dashboard/crm/listSort';
import {
  groupTasksByTime,
  visibleTaskTimeBuckets,
} from 'dashboard/routes/dashboard/crm/taskTimeBuckets';

const props = defineProps({
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
  showSortToggle: {
    type: Boolean,
    default: false,
  },
  sortDirectionLabels: {
    type: Object,
    default: () => ({}),
  },
  sortDirections: {
    type: Object,
    default: () => ({}),
  },
  sortKey: {
    type: String,
    default: 'position',
  },
  sortValueResolver: {
    type: Function,
    default: null,
  },
  statusNames: {
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

const emit = defineEmits([
  'changeAssignee',
  'selectTask',
  'toggleSortDirection',
]);
const { locale, t } = useI18n();

const localeCode = computed(
  () => locale.value?.replace(/_/g, '-') || undefined
);
const now = ref(new Date());
let clockIntervalId;
onMounted(() => {
  clockIntervalId = window.setInterval(() => {
    now.value = new Date();
  }, 60_000);
});
onUnmounted(() => window.clearInterval(clockIntervalId));

const groupedTasks = computed(() => groupTasksByTime(props.tasks, now.value));

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
  visibleTaskTimeBuckets(groupedTasks.value).map(key => {
    const direction =
      props.sortKey === 'position' ? 'asc' : props.sortDirections[key] || 'asc';
    const tasks = props.sortValueResolver
      ? sortListRecords(
          groupedTasks.value[key],
          { direction, key: props.sortKey },
          props.sortValueResolver
        )
      : groupedTasks.value[key];

    return {
      ...bucketMeta.value[key],
      direction,
      key,
      tasks,
    };
  })
);

const activityTypeMetaByValue = computed(() => ({
  call: {
    icon: 'i-lucide-phone',
    label: t('CRM.TASKS.ACTIVITY_TYPE.call'),
  },
  meeting: {
    icon: 'i-lucide-users',
    label: t('CRM.TASKS.ACTIVITY_TYPE.meeting'),
  },
  message: {
    icon: 'i-lucide-message-square',
    label: t('CRM.TASKS.ACTIVITY_TYPE.message'),
  },
  task: {
    icon: 'i-lucide-list-todo',
    label: t('CRM.TASKS.ACTIVITY_TYPE.task'),
  },
  touch: {
    icon: 'i-lucide-handshake',
    label: t('CRM.TASKS.ACTIVITY_TYPE.touch'),
  },
}));

const formatDateLabel = value => {
  if (!value) return t('CRM.TASKS.BOARD.TIME_BUCKETS.UNSCHEDULED');

  return new Intl.DateTimeFormat(localeCode.value, {
    day: 'numeric',
    hour: '2-digit',
    minute: '2-digit',
    month: 'short',
  }).format(new Date(value));
};

const activityTypeMeta = task =>
  activityTypeMetaByValue.value[task.activityType || 'task'] ||
  activityTypeMetaByValue.value.task;

const handleAssigneeChange = (task, assigneeId) => {
  const nextAssigneeId = Number(assigneeId);
  if (!nextAssigneeId || Number(task.assigneeId) === nextAssigneeId) return;

  emit('changeAssignee', { assigneeId: nextAssigneeId, task });
};
</script>

<template>
  <div class="flex h-full min-h-0 flex-col overflow-auto px-1 pb-2">
    <p
      class="sticky left-0 z-10 mx-3 my-1 w-max max-w-[calc(100vw-2rem)] rounded-md bg-n-surface-1 px-2 py-1 text-xs text-n-slate-11 shadow-sm"
      data-test="planning-only-note"
    >
      {{ t('CRM.TASKS.BOARD.PLANNING_ONLY') }}
    </p>
    <div class="mx-auto flex w-max min-h-full items-stretch gap-0 py-1">
      <section
        v-for="column in boardColumns"
        :key="column.key"
        :data-test="`bucket-${column.key}`"
        class="crm-task-board-column flex min-h-full w-[18rem] shrink-0 self-stretch flex-col overflow-visible"
      >
        <header
          class="sticky top-0 z-10 bg-n-slate-2/95 px-3 pt-3 pb-1.5 backdrop-blur supports-[backdrop-filter]:bg-n-slate-2/80"
        >
          <div class="flex items-center justify-between gap-3">
            <div class="flex min-w-0 items-center gap-2">
              <h3 class="mb-0 truncate text-sm font-semibold text-n-slate-12">
                {{ column.label }}
              </h3>
              <span
                class="rounded-full bg-n-alpha-black2 px-2 py-0.5 text-xs font-medium text-n-slate-11"
              >
                {{ column.tasks.length }}
              </span>
            </div>
            <button
              v-if="showSortToggle"
              type="button"
              class="inline-flex size-7 shrink-0 items-center justify-center rounded-md text-n-slate-11 hover:bg-n-alpha-black2 hover:text-n-slate-12 focus-visible:outline focus-visible:outline-2 focus-visible:outline-n-weak"
              :aria-label="sortDirectionLabels[column.direction]"
              :title="sortDirectionLabels[column.direction]"
              @click="emit('toggleSortDirection', column.key)"
            >
              <span
                class="size-4"
                :class="
                  column.direction === 'desc'
                    ? 'i-lucide-arrow-down-wide-narrow'
                    : 'i-lucide-arrow-up-narrow-wide'
                "
                aria-hidden="true"
              />
            </button>
          </div>
          <div
            class="crm-task-board-bucket-color mt-3 h-1 overflow-hidden rounded-full"
            :style="{ backgroundColor: column.color }"
          />
        </header>

        <div class="flex min-h-[5rem] flex-col gap-3 px-3 pb-3 pt-1.5">
          <article
            v-for="task in column.tasks"
            :key="task.id"
            class="rounded-md border border-n-weak bg-n-surface-1 px-2.5 py-2 shadow-sm transition-shadow hover:shadow-md"
            @click="emit('selectTask', task)"
          >
            <div class="flex items-start justify-between gap-2">
              <button
                type="button"
                data-test="open-task"
                class="min-w-0 text-left focus-visible:rounded focus-visible:outline focus-visible:outline-2 focus-visible:outline-offset-2 focus-visible:outline-n-brand"
                @click.stop="emit('selectTask', task)"
              >
                <h4 class="mb-0 truncate text-xs font-semibold text-n-slate-12">
                  {{ task.title }}
                </h4>
                <p
                  v-if="dealNames[task.dealId]"
                  class="mb-0 mt-0.5 text-[10px] text-n-slate-11"
                >
                  {{ dealNames[task.dealId] }}
                </p>
              </button>

              <CrmTaskAssigneeMenu
                :assignees="assignees"
                :disabled="!canManage"
                :model-value="task.assigneeId"
                @update:model-value="handleAssigneeChange(task, $event)"
              />
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
                {{ formatDateLabel(task.dueAt) }}
              </span>
            </div>

            <p
              v-if="statusNames[task.statusId]"
              class="mb-0 mt-2 text-[10px] text-n-slate-11"
            >
              {{ statusNames[task.statusId] }}
            </p>

            <CrmCustomFieldsSummary
              class="mt-2"
              :definitions="fieldDefinitions"
              :values="task.customAttributes"
            />
          </article>
        </div>
      </section>
    </div>
  </div>
</template>
