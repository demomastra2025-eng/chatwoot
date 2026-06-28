<script setup>
import { computed, ref, watch } from 'vue';
import { useI18n } from 'vue-i18n';
import Draggable from 'vuedraggable';

import CrmCustomFieldsSummary from './CrmCustomFieldsSummary.vue';
import CrmDealOwnerMenu from './CrmDealOwnerMenu.vue';
import { formatDealAmount, resolveDealAmountMajor } from './dealAmount';
import { sortListRecords } from 'dashboard/routes/dashboard/crm/listSort';
import { DEFAULT_STAGE_COLOR } from 'dashboard/stores/crm/stageColors';

const props = defineProps({
  canManage: {
    type: Boolean,
    default: false,
  },
  canReorder: {
    type: Boolean,
    default: true,
  },
  deals: {
    type: Array,
    default: () => [],
  },
  fieldDefinitions: {
    type: Array,
    default: () => [],
  },
  owners: {
    type: Array,
    default: () => [],
  },
  showSortToggle: {
    type: Boolean,
    default: false,
  },
  sortDirectionLabels: {
    type: Object,
    default: () => ({
      asc: '',
      desc: '',
    }),
  },
  sortDirections: {
    type: Object,
    default: () => ({}),
  },
  sortKey: {
    type: String,
    default: '',
  },
  stages: {
    type: Array,
    default: () => [],
  },
  sortValueResolver: {
    type: Function,
    default: null,
  },
});

const emit = defineEmits([
  'changeOwner',
  'changeStage',
  'createDeal',
  'selectDeal',
  'toggleSortDirection',
]);
const { locale, t } = useI18n();

const boardColumns = ref({});
const canDragDeals = computed(() => props.canManage && props.canReorder);
const localeCode = computed(
  () => locale.value?.replace(/_/g, '-') || undefined
);

const createBoardState = () =>
  props.stages.reduce((result, stage) => {
    result[Number(stage.id)] = [];
    return result;
  }, {});

const columnSortDirection = columnId => {
  if (props.sortKey === 'position') {
    return 'asc';
  }

  return props.sortDirections?.[columnId] === 'desc' ? 'desc' : 'asc';
};

const sortDirectionIcon = columnId =>
  columnSortDirection(columnId) === 'asc'
    ? 'i-lucide-arrow-up'
    : 'i-lucide-arrow-down';

const sortDirectionLabel = columnId =>
  props.sortDirectionLabels?.[columnSortDirection(columnId)] || '';

const resolveBoardPosition = index =>
  props.sortKey === 'position' ? index + 1 : null;

const sortColumnDeals = (items, columnId) => {
  if (!props.sortKey || !props.sortValueResolver) {
    return items;
  }

  return sortListRecords(
    items,
    {
      direction: columnSortDirection(columnId),
      key: props.sortKey,
    },
    props.sortValueResolver
  );
};

const syncBoardColumns = () => {
  const nextColumns = createBoardState();
  const fallbackStageId = Number(props.stages[0]?.id);

  props.deals.forEach(deal => {
    const dealStageId = Number(deal.stageId);
    const stageId = nextColumns[dealStageId] ? dealStageId : fallbackStageId;

    if (!stageId) return;

    nextColumns[stageId].push({ ...deal, stageId });
  });

  Object.keys(nextColumns).forEach(stageId => {
    nextColumns[stageId] = sortColumnDeals(nextColumns[stageId], stageId);
  });

  boardColumns.value = nextColumns;
};

watch(
  [
    () => props.deals,
    () => props.stages,
    () => props.sortDirections,
    () => props.sortKey,
  ],
  () => syncBoardColumns(),
  {
    deep: true,
    immediate: true,
  }
);

const kanbanColumns = computed(() =>
  props.stages.map(stage => ({
    color: stage.color,
    deals: boardColumns.value[Number(stage.id)] || [],
    label: stage.name,
    pipelineId: Number(stage.pipelineId),
    stageId: Number(stage.id),
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

const formatAmountLabel = deal => {
  return formatDealAmount({
    amount: resolveDealAmountMajor(deal),
    currency: deal.currency,
    emptyValue: t('CRM.GENERAL.EMPTY_VALUE'),
    locale: localeCode.value,
  });
};

const dealSubtitle = deal => {
  return deal.primaryContact?.name || '';
};

const emitStageChange = (deal, stageId, position) => {
  const nextStageId = Number(stageId);
  const nextPosition = Number(position);

  if (
    !deal ||
    (Number(deal.stageId) === nextStageId &&
      (!nextPosition || Number(deal.position) === nextPosition))
  ) {
    return;
  }

  emit('changeStage', {
    deal,
    position: nextPosition || null,
    stageId: nextStageId,
  });
};

const handleColumnChange = (event, stageId) => {
  if (event.moved) {
    const deal = boardColumns.value[Number(stageId)][event.moved.newIndex];
    emitStageChange(deal, stageId, resolveBoardPosition(event.moved.newIndex));
    return;
  }

  if (!event.added) return;

  const deal = boardColumns.value[Number(stageId)][event.added.newIndex];
  emitStageChange(deal, stageId, resolveBoardPosition(event.added.newIndex));
};

const handleOwnerChange = (deal, ownerId) => {
  const nextOwnerId = Number(ownerId);

  if (!nextOwnerId || Number(deal.ownerId) === nextOwnerId) {
    return;
  }

  emit('changeOwner', { deal, ownerId: nextOwnerId });
};
</script>

<template>
  <div class="flex h-full min-h-0 flex-col overflow-auto px-1 pb-2">
    <div class="mx-auto flex w-max min-h-full items-start gap-2 py-1">
      <section
        v-for="column in kanbanColumns"
        :key="column.stageId"
        class="crm-deal-board-column group/crm-column flex min-h-full w-[17rem] shrink-0 self-start flex-col overflow-visible"
      >
        <header
          class="sticky top-0 z-10 rounded-t-xl bg-n-slate-2/95 px-4 pt-3 pb-1.5 backdrop-blur supports-[backdrop-filter]:bg-n-slate-2/80"
        >
          <div class="flex items-start justify-between gap-3">
            <div class="min-w-0">
              <h3 class="mb-0 truncate text-sm font-semibold text-n-slate-12">
                {{ column.label }}
              </h3>
            </div>
            <div class="flex items-center gap-2">
              <span
                class="rounded-full bg-n-alpha-black2 px-2 py-0.5 text-xs font-medium text-n-slate-11"
              >
                {{ column.deals.length }}
              </span>
              <button
                v-if="showSortToggle"
                type="button"
                class="flex size-8 shrink-0 items-center justify-center rounded-md border border-transparent bg-transparent text-n-slate-11 transition-colors hover:bg-n-alpha-black2 hover:text-n-slate-12"
                :aria-label="sortDirectionLabel(column.stageId)"
                :title="sortDirectionLabel(column.stageId)"
                @click.stop="emit('toggleSortDirection', column.stageId)"
              >
                <i
                  class="text-base"
                  :class="sortDirectionIcon(column.stageId)"
                  aria-hidden="true"
                />
              </button>
            </div>
          </div>
          <div class="mt-3 h-1 overflow-hidden rounded-full bg-n-alpha-black2">
            <div
              class="h-full rounded-full"
              :style="{
                backgroundColor: column.color || DEFAULT_STAGE_COLOR,
              }"
            />
          </div>
        </header>

        <Draggable
          :list="boardColumns[column.stageId]"
          :disabled="!canDragDeals"
          :sort="canDragDeals && sortKey === 'position'"
          animation="180"
          class="flex min-h-[5rem] flex-col gap-3 px-3 pb-3 pt-1.5"
          ghost-class="crm-deal-board-card-ghost"
          group="crm-deal-board"
          item-key="id"
          @change="handleColumnChange($event, column.stageId)"
        >
          <template #item="{ element }">
            <article
              class="rounded-md border border-n-weak bg-n-surface-1 px-2.5 py-2 shadow-sm transition-shadow hover:shadow-md"
              @click="emit('selectDeal', element)"
            >
              <div class="flex items-start justify-between gap-2">
                <div class="min-w-0">
                  <div class="flex min-w-0 items-center gap-1.5">
                    <h4
                      class="mb-0 min-w-0 truncate text-xs font-semibold text-n-slate-12"
                    >
                      {{ element.title }}
                    </h4>
                    <span
                      v-if="element.dialogStatus === 'pending'"
                      class="shrink-0 rounded-full bg-n-violet-3 px-1.5 py-0.5 text-[9px] font-semibold uppercase tracking-wide text-n-violet-9 ring-1 ring-inset ring-n-violet-6/20"
                    >
                      {{ $t('CRM.DEALS.AI_BADGE') }}
                    </span>
                  </div>
                  <p class="mb-0 mt-0.5 text-[10px] text-n-slate-11">
                    {{ dealSubtitle(element) || $t('CRM.GENERAL.EMPTY_VALUE') }}
                  </p>
                </div>

                <span
                  class="shrink-0 text-right text-[10px] font-medium tabular-nums text-n-slate-10"
                >
                  {{ formatAmountLabel(element) }}
                </span>
              </div>

              <div class="mt-2 flex items-start justify-between gap-2">
                <div class="flex min-w-0 items-center gap-2">
                  <CrmDealOwnerMenu
                    :disabled="!canManage"
                    :model-value="element.ownerId"
                    :owners="owners"
                    @update:model-value="handleOwnerChange(element, $event)"
                  />
                  <span
                    v-if="element.archivedAt"
                    class="rounded-full bg-n-amber-9/10 px-2 py-1 text-[10px] font-medium text-n-amber-11"
                  >
                    {{ $t('CRM.GENERAL.ARCHIVED') }}
                  </span>
                </div>
                <span class="text-[9px] text-n-slate-10/90">
                  {{
                    formatDateLabel(
                      element.expectedCloseOn || element.updatedAt
                    )
                  }}
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
            <template v-if="!column.deals.length">
              <div v-if="canManage" class="block">
                <button
                  type="button"
                  class="flex w-full items-center justify-center gap-1.5 rounded-md border border-dashed border-n-strong bg-transparent px-2.5 py-2 text-[10px] font-medium text-n-slate-12 transition-colors hover:bg-n-alpha-1"
                  @click.stop="
                    emit('createDeal', {
                      pipelineId: column.pipelineId,
                      stageId: column.stageId,
                    })
                  "
                >
                  <span class="size-3 i-lucide-plus" aria-hidden="true" />
                  <span>{{ $t('CRM.DEALS.NEW_DEAL') }}</span>
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
                  emit('createDeal', {
                    pipelineId: column.pipelineId,
                    stageId: column.stageId,
                  })
                "
              >
                <span class="size-3 i-lucide-plus" aria-hidden="true" />
                <span>{{ $t('CRM.DEALS.NEW_DEAL') }}</span>
              </button>
            </div>
          </template>
        </Draggable>
      </section>
    </div>
  </div>
</template>

<style scoped lang="scss">
.crm-deal-board-card-ghost {
  @apply opacity-40;
}

.crm-deal-board-column {
  @apply relative;
}

.crm-deal-board-column + .crm-deal-board-column::before {
  content: '';
  @apply absolute -left-1 top-1/2 h-1/3 w-px -translate-y-1/2 bg-n-weak;
}
</style>
