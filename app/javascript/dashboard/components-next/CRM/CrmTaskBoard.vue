<script setup>
import { computed, ref, watch } from 'vue';
import { useI18n } from 'vue-i18n';
import Draggable from 'vuedraggable';

import CrmCustomFieldsSummary from './CrmCustomFieldsSummary.vue';
import CrmTaskAssigneeMenu from './CrmTaskAssigneeMenu.vue';
import { DEFAULT_TASK_STATUS_COLOR } from 'dashboard/stores/crm/taskStatusColors';

const props = defineProps({
  assignees: {
    type: Array,
    default: () => [],
  },
  canManage: {
    type: Boolean,
    default: false,
  },
  fieldDefinitions: {
    type: Array,
    default: () => [],
  },
  dealNames: {
    type: Object,
    default: () => ({}),
  },
  statuses: {
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
  'changeStatus',
  'createTask',
  'selectTask',
]);
const { locale, t } = useI18n();

const boardColumns = ref({});
const localeCode = computed(
  () => locale.value?.replace(/_/g, '-') || undefined
);

const createBoardState = () =>
  props.statuses.reduce((result, status) => {
    result[Number(status.id)] = [];
    return result;
  }, {});

const getTaskSortTime = task => {
  const sortValue =
    task.dueAt || task.startAt || task.updatedAt || task.createdAt;
  const timestamp = new Date(sortValue).getTime();

  return Number.isNaN(timestamp) ? 0 : timestamp;
};

const sortedTasks = tasks =>
  [...tasks].sort(
    (left, right) => getTaskSortTime(left) - getTaskSortTime(right)
  );

const syncBoardColumns = () => {
  const nextColumns = createBoardState();
  const fallbackStatusId = Number(props.statuses[0]?.id);

  sortedTasks(props.tasks).forEach(task => {
    const taskStatusId = Number(task.statusId);
    const statusId = nextColumns[taskStatusId]
      ? taskStatusId
      : fallbackStatusId;

    if (!statusId) return;

    nextColumns[statusId].push({ ...task, statusId });
  });

  boardColumns.value = nextColumns;
};

watch([() => props.tasks, () => props.statuses], () => syncBoardColumns(), {
  deep: true,
  immediate: true,
});

const kanbanColumns = computed(() =>
  props.statuses.map(status => ({
    color: status.color,
    label: status.name,
    statusId: Number(status.id),
    tasks: boardColumns.value[Number(status.id)] || [],
  }))
);

const formatDateLabel = value => {
  if (!value) return t('CRM.GENERAL.EMPTY_VALUE');

  return new Intl.DateTimeFormat(localeCode.value, {
    day: 'numeric',
    month: 'short',
    weekday: 'short',
  }).format(new Date(value));
};

const priorityLabelByValue = computed(() => ({
  high: t('CRM.TASKS.PRIORITY.high'),
  low: t('CRM.TASKS.PRIORITY.low'),
  medium: t('CRM.TASKS.PRIORITY.medium'),
  none: t('CRM.TASKS.PRIORITY.none'),
  urgent: t('CRM.TASKS.PRIORITY.urgent'),
}));

const formatPriorityLabel = priority => {
  if (!priority) return t('CRM.GENERAL.EMPTY_VALUE');

  return priorityLabelByValue.value[priority] || priority;
};

const taskSubtitle = task => {
  return props.dealNames[task.dealId] || '';
};

const emitStatusChange = (task, statusId) => {
  const nextStatusId = Number(statusId);

  if (!task || Number(task.statusId) === nextStatusId) return;

  task.statusId = nextStatusId;
  emit('changeStatus', { statusId: nextStatusId, task });
};

const handleColumnChange = (event, statusId) => {
  if (!event.added) return;

  const task = boardColumns.value[Number(statusId)][event.added.newIndex];
  emitStatusChange(task, statusId);
};

const handleAssigneeChange = (task, assigneeId) => {
  const nextAssigneeId = Number(assigneeId);

  if (!nextAssigneeId || Number(task.assigneeId) === nextAssigneeId) {
    return;
  }

  emit('changeAssignee', { assigneeId: nextAssigneeId, task });
};
</script>

<template>
  <div class="flex h-full min-h-0 flex-col">
    <div class="min-h-0 flex-1 overflow-x-auto overflow-y-hidden px-1 pb-2">
      <div class="mx-auto flex h-full w-max items-stretch gap-2 py-1">
        <section
          v-for="column in kanbanColumns"
          :key="column.statusId"
          class="crm-task-board-column group/crm-column flex h-full min-h-0 w-[17rem] shrink-0 flex-col overflow-visible"
        >
          <header class="px-4 pt-3 pb-1.5">
            <div class="flex items-start justify-between gap-3">
              <div class="min-w-0">
                <h3 class="mb-0 truncate text-sm font-semibold text-n-slate-12">
                  {{ column.label }}
                </h3>
              </div>
              <span
                class="rounded-full bg-n-alpha-black2 px-2 py-0.5 text-xs font-medium text-n-slate-11"
              >
                {{ column.tasks.length }}
              </span>
            </div>
            <div
              class="mt-3 h-1 overflow-hidden rounded-full bg-n-alpha-black2"
            >
              <div
                class="h-full rounded-full"
                :style="{
                  backgroundColor: column.color || DEFAULT_TASK_STATUS_COLOR,
                }"
              />
            </div>
          </header>

          <Draggable
            :list="boardColumns[column.statusId]"
            :disabled="!canManage"
            animation="180"
            class="flex min-h-0 flex-1 flex-col gap-3 overflow-y-auto px-3 pb-3 pt-1.5"
            ghost-class="crm-task-board-card-ghost"
            group="crm-task-board"
            item-key="id"
            @change="handleColumnChange($event, column.statusId)"
          >
            <template #item="{ element }">
              <article
                class="rounded-md border border-n-weak bg-n-surface-1 px-2.5 py-2 shadow-sm transition-shadow hover:shadow-md"
                @click="emit('selectTask', element)"
              >
                <div class="flex items-start justify-between gap-2">
                  <div class="min-w-0">
                    <h4
                      class="mb-0 truncate text-xs font-semibold text-n-slate-12"
                    >
                      {{ element.title }}
                    </h4>
                    <p
                      v-if="taskSubtitle(element)"
                      class="mb-0 mt-0.5 text-[10px] text-n-slate-11"
                    >
                      {{ taskSubtitle(element) }}
                    </p>
                  </div>

                  <CrmTaskAssigneeMenu
                    :assignees="assignees"
                    :disabled="!canManage"
                    :model-value="element.assigneeId"
                    @update:model-value="handleAssigneeChange(element, $event)"
                  />
                </div>

                <div class="mt-2 flex items-center justify-between gap-2">
                  <span
                    v-if="element.archivedAt"
                    class="rounded-full bg-n-amber-9/10 px-2 py-1 text-[10px] font-medium text-n-amber-11"
                  >
                    {{ $t('CRM.GENERAL.ARCHIVED') }}
                  </span>
                  <span
                    v-else
                    class="text-[10px] font-medium leading-none tracking-normal text-n-slate-10"
                  >
                    {{ formatPriorityLabel(element.priority) }}
                  </span>

                  <span class="text-[9px] text-n-slate-10/90">
                    {{ formatDateLabel(element.dueAt || element.updatedAt) }}
                  </span>
                </div>

                <CrmCustomFieldsSummary
                  class="mt-2"
                  :definitions="fieldDefinitions"
                  :values="element.customAttributes"
                />
              </article>
            </template>

            <template #footer>
              <template v-if="!column.tasks.length">
                <div v-if="canManage" class="block">
                  <button
                    type="button"
                    class="flex w-full items-center justify-center gap-1.5 rounded-md border border-dashed border-n-strong bg-transparent px-2.5 py-2 text-[10px] font-medium text-n-slate-12 transition-colors hover:bg-n-alpha-1"
                    @click.stop="
                      emit('createTask', {
                        statusId: column.statusId,
                      })
                    "
                  >
                    <span class="size-3 i-lucide-plus" aria-hidden="true" />
                    <span>{{ $t('CRM.TASKS.NEW_TASK') }}</span>
                  </button>
                </div>
              </template>

              <div
                v-else-if="canManage"
                class="hidden group-hover/crm-column:block group-focus-within/crm-column:block"
              >
                <button
                  type="button"
                  class="flex w-full items-center justify-center gap-1.5 rounded-md border border-dashed border-n-strong bg-transparent px-2.5 py-2 text-[10px] font-medium text-n-slate-12 transition-colors hover:bg-n-alpha-1"
                  @click.stop="
                    emit('createTask', {
                      statusId: column.statusId,
                    })
                  "
                >
                  <span class="size-3 i-lucide-plus" aria-hidden="true" />
                  <span>{{ $t('CRM.TASKS.NEW_TASK') }}</span>
                </button>
              </div>
            </template>
          </Draggable>
        </section>
      </div>
    </div>
  </div>
</template>

<style scoped lang="scss">
.crm-task-board-card-ghost {
  @apply opacity-40;
}

.crm-task-board-column {
  @apply relative;
}

.crm-task-board-column + .crm-task-board-column::before {
  content: '';
  @apply absolute -left-1 top-1/2 h-1/3 w-px -translate-y-1/2 bg-n-weak;
}
</style>
