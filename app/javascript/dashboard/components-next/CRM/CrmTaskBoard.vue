<script setup>
import { computed, ref, watch } from 'vue';
import { useI18n } from 'vue-i18n';
import Draggable from 'vuedraggable';

import CrmTaskStatusMenu from './CrmTaskStatusMenu.vue';

const props = defineProps({
  assigneeNames: {
    type: Object,
    default: () => ({}),
  },
  canManage: {
    type: Boolean,
    default: false,
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

const emit = defineEmits(['changeStatus', 'selectTask']);
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

const taskSubtitle = task => {
  return [props.dealNames[task.dealId], props.assigneeNames[task.assigneeId]]
    .filter(Boolean)
    .join(' · ');
};

const emitStatusChange = (task, statusId) => {
  const nextStatusId = Number(statusId);

  if (!task || Number(task.statusId) === nextStatusId) return;

  task.statusId = nextStatusId;
  emit('changeStatus', { statusId: nextStatusId, task });
};

const moveTaskToStatus = (task, nextStatusId) => {
  const normalizedStatusId = Number(nextStatusId);
  const currentStatusId = props.statuses.find(status =>
    (boardColumns.value[Number(status.id)] || []).some(
      item => item.id === task.id
    )
  )?.id;

  if (!currentStatusId || Number(currentStatusId) === normalizedStatusId) {
    return;
  }

  boardColumns.value[Number(currentStatusId)] = boardColumns.value[
    Number(currentStatusId)
  ].filter(item => item.id !== task.id);

  const updatedTask = { ...task, statusId: normalizedStatusId };
  boardColumns.value[normalizedStatusId] = [
    updatedTask,
    ...(boardColumns.value[normalizedStatusId] || []),
  ];

  emit('changeStatus', {
    statusId: normalizedStatusId,
    task: updatedTask,
  });
};

const handleColumnChange = (event, statusId) => {
  if (!event.added) return;

  const task = boardColumns.value[Number(statusId)][event.added.newIndex];
  emitStatusChange(task, statusId);
};
</script>

<template>
  <div class="flex h-full min-h-0 flex-col">
    <div class="min-h-0 flex-1 overflow-x-auto overflow-y-hidden px-1 pb-2">
      <div class="flex h-full min-w-max items-stretch gap-4 py-1">
        <section
          v-for="column in kanbanColumns"
          :key="column.statusId"
          class="flex h-full min-h-0 w-[17rem] shrink-0 flex-col overflow-hidden rounded-2xl bg-n-solid-2 outline outline-1 outline-n-container"
        >
          <header
            class="flex items-center justify-between gap-3 border-b border-n-weak bg-n-surface-2 px-4 py-3"
          >
            <h3 class="mb-0 truncate text-sm font-semibold text-n-slate-12">
              {{ column.label }}
            </h3>
            <span
              class="rounded-full bg-n-alpha-black2 px-2 py-0.5 text-xs font-medium text-n-slate-11"
            >
              {{ column.tasks.length }}
            </span>
          </header>

          <Draggable
            :list="boardColumns[column.statusId]"
            :disabled="!canManage"
            animation="180"
            class="flex min-h-0 flex-1 flex-col gap-3 overflow-y-auto p-3"
            ghost-class="crm-task-board-card-ghost"
            group="crm-task-board"
            item-key="id"
            @change="handleColumnChange($event, column.statusId)"
          >
            <template #item="{ element }">
              <article
                class="rounded-2xl border border-n-weak bg-n-surface-1 p-3 shadow-sm transition-shadow hover:shadow-md"
                @click="emit('selectTask', element)"
              >
                <div class="flex items-start justify-between gap-3">
                  <div class="min-w-0">
                    <h4
                      class="mb-0 truncate text-sm font-semibold text-n-slate-12"
                    >
                      {{ element.title }}
                    </h4>
                    <p class="mb-0 mt-1 text-xs text-n-slate-11">
                      {{
                        taskSubtitle(element) || $t('CRM.GENERAL.EMPTY_VALUE')
                      }}
                    </p>
                  </div>

                  <CrmTaskStatusMenu
                    :disabled="!canManage"
                    :model-value="element.statusId"
                    neutral
                    :statuses="statuses"
                    @update:model-value="moveTaskToStatus(element, $event)"
                  />
                </div>

                <div class="mt-3 flex items-center justify-between gap-3">
                  <span
                    v-if="element.archivedAt"
                    class="rounded-full bg-n-amber-9/10 px-2 py-1 text-[11px] font-medium text-n-amber-11"
                  >
                    {{ $t('CRM.GENERAL.ARCHIVED') }}
                  </span>
                  <span
                    v-else
                    class="text-xs font-medium uppercase tracking-[0.06em] text-n-slate-10"
                  >
                    {{ element.priority || $t('CRM.GENERAL.EMPTY_VALUE') }}
                  </span>

                  <span class="text-xs text-n-slate-11">
                    {{ formatDateLabel(element.dueAt || element.updatedAt) }}
                  </span>
                </div>
              </article>
            </template>

            <template #footer>
              <div
                v-if="!column.tasks.length"
                class="flex min-h-[8rem] flex-1 items-center justify-center rounded-2xl border border-dashed border-n-strong bg-n-alpha-black2 px-4 text-center text-sm text-n-slate-11"
              >
                {{ $t('CRM.TASKS.BOARD.EMPTY_COLUMN') }}
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
</style>
