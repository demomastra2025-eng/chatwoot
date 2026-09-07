<script setup>
import {
  computed,
  nextTick,
  onBeforeUnmount,
  onMounted,
  ref,
  watch,
} from 'vue';
import { useI18n } from 'vue-i18n';
import Draggable from 'vuedraggable';

import CrmCustomFieldsSummary from './CrmCustomFieldsSummary.vue';
import { formatDealAmount, resolveDealAmountMajor } from './dealAmount';
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
  hasMore: {
    type: Boolean,
    default: false,
  },
  isLoadingMore: {
    type: Boolean,
    default: false,
  },
  loadMoreFailed: {
    type: Boolean,
    default: false,
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
  stageCounts: {
    type: Object,
    default: () => ({}),
  },
});

const emit = defineEmits([
  'changeStage',
  'loadMore',
  'selectDeal',
  'toggleSortDirection',
]);
const { locale, t } = useI18n();

const boardColumns = ref({});
const boardScrollContainer = ref(null);
const canDragDeals = computed(() => props.canManage && props.canReorder);
const ownerNameById = computed(() =>
  props.owners.reduce((result, owner) => {
    result[Number(owner.value)] = owner.label;
    return result;
  }, {})
);
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

const syncBoardColumns = () => {
  const nextColumns = createBoardState();
  const fallbackStageId = Number(props.stages[0]?.id);

  props.deals.forEach(deal => {
    const dealStageId = Number(deal.stageId);
    const stageId = nextColumns[dealStageId] ? dealStageId : fallbackStageId;

    if (!stageId) return;

    nextColumns[stageId].push({ ...deal, stageId });
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
    stageId: Number(stage.id),
  }))
);

const columnDealCount = column =>
  Number(props.stageCounts?.[String(column.stageId)]) || column.deals.length;

let lastBoardScrollTop = 0;
let lastAutoFillSignature = null;
let resizeObserver = null;

const loadMoreIfBoardDoesNotOverflow = async () => {
  await nextTick();
  const element = boardScrollContainer.value;
  if (
    !element ||
    !props.hasMore ||
    props.isLoadingMore ||
    props.loadMoreFailed
  ) {
    return;
  }
  if (element.scrollHeight > element.clientHeight + 1) return;

  const dealSignature = props.deals.map(deal => deal.id).join(',');
  if (lastAutoFillSignature === dealSignature) return;

  lastAutoFillSignature = dealSignature;
  emit('loadMore');
};

watch(
  [
    () => props.deals.map(deal => deal.id).join(','),
    () => props.hasMore,
    () => props.isLoadingMore,
  ],
  () => loadMoreIfBoardDoesNotOverflow(),
  { flush: 'post' }
);

onMounted(() => {
  loadMoreIfBoardDoesNotOverflow();
  if (typeof ResizeObserver === 'undefined') return;

  resizeObserver = new ResizeObserver(() => loadMoreIfBoardDoesNotOverflow());
  resizeObserver.observe(boardScrollContainer.value);
});

onBeforeUnmount(() => resizeObserver?.disconnect());

const handleBoardScroll = event => {
  const element = event.currentTarget;
  const isScrollingDown = element.scrollTop > lastBoardScrollTop;
  lastBoardScrollTop = element.scrollTop;
  if (!props.hasMore || props.isLoadingMore) return;
  if (!isScrollingDown) return;

  const distanceToBottom =
    element.scrollHeight - element.scrollTop - element.clientHeight;

  if (distanceToBottom < 320) {
    emit('loadMore');
  }
};

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

const taskNextActionLabel = nextAction => {
  const params = { title: nextAction.task?.title };
  if (nextAction.state === 'overdue') {
    return t('CRM.DEALS.NEXT_ACTION.OVERDUE', params);
  }
  if (nextAction.state === 'today') {
    return t('CRM.DEALS.NEXT_ACTION.TODAY', params);
  }
  if (nextAction.state === 'unscheduled') {
    return t('CRM.DEALS.NEXT_ACTION.UNSCHEDULED', params);
  }

  return t('CRM.DEALS.NEXT_ACTION.FUTURE', params);
};

const nextActionLabel = deal => {
  const nextAction = deal.nextAction || {};
  if (nextAction.kind === 'waiting') {
    return t('CRM.DEALS.NEXT_ACTION.WAITING', {
      date: formatDateLabel(deal.waitingUntil),
    });
  }
  if (nextAction.kind === 'waitingExpired') {
    return t('CRM.DEALS.NEXT_ACTION.WAITING_EXPIRED');
  }
  if (nextAction.kind === 'task') {
    return taskNextActionLabel(nextAction);
  }

  return t('CRM.DEALS.NEXT_ACTION.NONE');
};

const nextActionClass = deal => {
  const { kind, state } = deal.nextAction || {};
  if (kind === 'waitingExpired' || state === 'overdue') {
    return 'bg-n-ruby-3 text-n-ruby-11';
  }
  if (kind === 'waiting' || state === 'today') {
    return 'bg-n-amber-3 text-n-amber-11';
  }
  if (kind === 'task') return 'bg-n-blue-3 text-n-blue-11';

  return 'bg-n-alpha-black2 text-n-slate-10';
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
</script>

<template>
  <div
    ref="boardScrollContainer"
    class="flex h-full min-h-0 flex-col overflow-auto px-1 pb-2"
    @scroll.passive="handleBoardScroll"
  >
    <div class="mx-auto flex w-max min-h-full items-stretch gap-0 py-1">
      <section
        v-for="column in kanbanColumns"
        :key="column.stageId"
        class="crm-deal-board-column flex min-h-full w-[18rem] shrink-0 self-stretch flex-col overflow-visible"
      >
        <header
          class="sticky top-0 z-10 bg-n-slate-2/95 px-3 pt-3 pb-1.5 backdrop-blur supports-[backdrop-filter]:bg-n-slate-2/80"
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
                {{ columnDealCount(column) }}
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
          <div
            class="crm-deal-board-stage-color mt-3 h-1 overflow-hidden rounded-full"
            :style="{
              backgroundColor: column.color || DEFAULT_STAGE_COLOR,
            }"
          />
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
                <button
                  type="button"
                  data-test="open-deal"
                  class="min-w-0 flex-1 overflow-hidden text-left focus-visible:rounded focus-visible:outline focus-visible:outline-2 focus-visible:outline-offset-2 focus-visible:outline-n-brand"
                >
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
                  <p class="mb-0 mt-0.5 truncate text-[10px] text-n-slate-11">
                    {{ dealSubtitle(element) || $t('CRM.GENERAL.EMPTY_VALUE') }}
                  </p>
                </button>

                <span
                  class="shrink-0 text-right text-[10px] font-medium tabular-nums text-n-slate-10"
                >
                  {{ formatAmountLabel(element) }}
                </span>
              </div>

              <div class="mt-2 flex items-start justify-between gap-2">
                <div class="flex min-w-0 items-center gap-2">
                  <span
                    class="max-w-[8.5rem] truncate rounded-md bg-n-alpha-black2 px-1.5 py-1 text-[9px] font-medium text-n-slate-12"
                  >
                    {{
                      ownerNameById[element.ownerId] ||
                      $t('CRM.GENERAL.EMPTY_VALUE')
                    }}
                  </span>
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

              <p
                class="mb-0 mt-2 truncate rounded-md px-1.5 py-1 text-[9px] font-medium"
                :class="nextActionClass(element)"
              >
                {{ nextActionLabel(element) }}
              </p>

              <CrmCustomFieldsSummary
                class="mt-2"
                :definitions="fieldDefinitions"
                :values="element.customAttributes"
              />
            </article>
          </template>
        </Draggable>
      </section>
    </div>
    <div
      v-if="loadMoreFailed && hasMore"
      class="sticky left-0 flex justify-center py-3"
    >
      <button
        type="button"
        class="rounded-md border border-n-weak bg-n-surface-1 px-3 py-2 text-sm font-medium text-n-slate-12 hover:bg-n-alpha-black2"
        @click="emit('loadMore')"
      >
        {{ $t('CRM.DEALS.RETRY_LOAD') }}
      </button>
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
