<script setup>
import { computed, ref, watch } from 'vue';
import { useI18n } from 'vue-i18n';
import Draggable from 'vuedraggable';

import CrmDealStageMenu from './CrmDealStageMenu.vue';

const props = defineProps({
  canManage: {
    type: Boolean,
    default: false,
  },
  deals: {
    type: Array,
    default: () => [],
  },
  ownerNames: {
    type: Object,
    default: () => ({}),
  },
  pipelineNames: {
    type: Object,
    default: () => ({}),
  },
  stages: {
    type: Array,
    default: () => [],
  },
});

const emit = defineEmits(['changeStage', 'selectDeal']);
const { locale, t } = useI18n();

const boardColumns = ref({});
const localeCode = computed(
  () => locale.value?.replace(/_/g, '-') || undefined
);

const createBoardState = () =>
  props.stages.reduce((result, stage) => {
    result[Number(stage.id)] = [];
    return result;
  }, {});

const getDealSortTime = deal => {
  const sortValue =
    deal.expectedCloseOn || deal.updatedAt || deal.createdAt || deal.id;
  const timestamp = new Date(sortValue).getTime();

  return Number.isNaN(timestamp) ? 0 : timestamp;
};

const sortedDeals = deals =>
  [...deals].sort(
    (left, right) => getDealSortTime(left) - getDealSortTime(right)
  );

const syncBoardColumns = () => {
  const nextColumns = createBoardState();
  const fallbackStageId = Number(props.stages[0]?.id);

  sortedDeals(props.deals).forEach(deal => {
    const dealStageId = Number(deal.stageId);
    const stageId = nextColumns[dealStageId] ? dealStageId : fallbackStageId;

    if (!stageId) return;

    nextColumns[stageId].push({ ...deal, stageId });
  });

  boardColumns.value = nextColumns;
};

watch([() => props.deals, () => props.stages], () => syncBoardColumns(), {
  deep: true,
  immediate: true,
});

const kanbanColumns = computed(() =>
  props.stages.map(stage => ({
    description: stage.pipelineName || '',
    deals: boardColumns.value[Number(stage.id)] || [],
    label: stage.name,
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
  if (!deal.amountMinor) {
    return t('CRM.GENERAL.EMPTY_VALUE');
  }

  return `${deal.amountMinor}${deal.currency ? ` ${deal.currency}` : ''}`;
};

const dealSubtitle = deal => {
  return [props.pipelineNames[deal.pipelineId], props.ownerNames[deal.ownerId]]
    .filter(Boolean)
    .join(' · ');
};

const emitStageChange = (deal, stageId) => {
  const nextStageId = Number(stageId);

  if (!deal || Number(deal.stageId) === nextStageId) return;

  deal.stageId = nextStageId;
  emit('changeStage', { deal, stageId: nextStageId });
};

const moveDealToStage = (deal, nextStageId) => {
  const normalizedStageId = Number(nextStageId);
  const currentStageId = props.stages.find(stage =>
    (boardColumns.value[Number(stage.id)] || []).some(
      item => item.id === deal.id
    )
  )?.id;

  if (!currentStageId || Number(currentStageId) === normalizedStageId) {
    return;
  }

  boardColumns.value[Number(currentStageId)] = boardColumns.value[
    Number(currentStageId)
  ].filter(item => item.id !== deal.id);

  const updatedDeal = { ...deal, stageId: normalizedStageId };
  boardColumns.value[normalizedStageId] = [
    updatedDeal,
    ...(boardColumns.value[normalizedStageId] || []),
  ];

  emit('changeStage', {
    deal: updatedDeal,
    stageId: normalizedStageId,
  });
};

const handleColumnChange = (event, stageId) => {
  if (!event.added) return;

  const deal = boardColumns.value[Number(stageId)][event.added.newIndex];
  emitStageChange(deal, stageId);
};
</script>

<template>
  <div class="flex h-full min-h-0 flex-col">
    <div class="min-h-0 flex-1 overflow-x-auto overflow-y-hidden px-1 pb-2">
      <div class="flex h-full min-w-max items-stretch gap-4 py-1">
        <section
          v-for="column in kanbanColumns"
          :key="column.stageId"
          class="flex h-full min-h-0 w-[17rem] shrink-0 flex-col overflow-hidden rounded-2xl bg-n-solid-2 outline outline-1 outline-n-container"
        >
          <header
            class="flex items-start justify-between gap-3 border-b border-n-weak bg-n-surface-2 px-4 py-3"
          >
            <div class="min-w-0">
              <h3 class="mb-0 truncate text-sm font-semibold text-n-slate-12">
                {{ column.label }}
              </h3>
              <p
                v-if="column.description"
                class="mb-0 mt-1 truncate text-xs text-n-slate-11"
              >
                {{ column.description }}
              </p>
            </div>
            <span
              class="rounded-full bg-n-alpha-black2 px-2 py-0.5 text-xs font-medium text-n-slate-11"
            >
              {{ column.deals.length }}
            </span>
          </header>

          <Draggable
            :list="boardColumns[column.stageId]"
            :disabled="!canManage"
            animation="180"
            class="flex min-h-0 flex-1 flex-col gap-3 overflow-y-auto p-3"
            ghost-class="crm-deal-board-card-ghost"
            group="crm-deal-board"
            item-key="id"
            @change="handleColumnChange($event, column.stageId)"
          >
            <template #item="{ element }">
              <article
                class="rounded-2xl border border-n-weak bg-n-surface-1 p-3 shadow-sm transition-shadow hover:shadow-md"
                @click="emit('selectDeal', element)"
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
                        dealSubtitle(element) || $t('CRM.GENERAL.EMPTY_VALUE')
                      }}
                    </p>
                  </div>

                  <CrmDealStageMenu
                    :disabled="!canManage"
                    :model-value="element.stageId"
                    :stages="stages"
                    @update:model-value="moveDealToStage(element, $event)"
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
                    {{ formatAmountLabel(element) }}
                  </span>

                  <span class="text-xs text-n-slate-11">
                    {{
                      formatDateLabel(
                        element.expectedCloseOn || element.updatedAt
                      )
                    }}
                  </span>
                </div>
              </article>
            </template>

            <template #footer>
              <div
                v-if="!column.deals.length"
                class="flex min-h-[8rem] flex-1 items-center justify-center rounded-2xl border border-dashed border-n-strong bg-n-alpha-black2 px-4 text-center text-sm text-n-slate-11"
              >
                {{ $t('CRM.DEALS.BOARD.EMPTY_COLUMN') }}
              </div>
            </template>
          </Draggable>
        </section>
      </div>
    </div>
  </div>
</template>

<style scoped lang="scss">
.crm-deal-board-card-ghost {
  @apply opacity-40;
}
</style>
