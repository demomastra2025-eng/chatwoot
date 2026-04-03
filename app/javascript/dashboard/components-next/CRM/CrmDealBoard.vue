<script setup>
import { computed, ref, watch } from 'vue';
import { useI18n } from 'vue-i18n';
import Draggable from 'vuedraggable';

import CrmCustomFieldsSummary from './CrmCustomFieldsSummary.vue';
import CrmDealOwnerMenu from './CrmDealOwnerMenu.vue';
import { formatDealAmount } from './dealAmount';
import { DEFAULT_STAGE_COLOR } from 'dashboard/stores/crm/stageColors';

const props = defineProps({
  canManage: {
    type: Boolean,
    default: false,
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
  stages: {
    type: Array,
    default: () => [],
  },
});

const emit = defineEmits([
  'changeOwner',
  'changeStage',
  'createDeal',
  'selectDeal',
]);
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
    amount: deal.amountMinor,
    currency: deal.currency,
    emptyValue: t('CRM.GENERAL.EMPTY_VALUE'),
    locale: localeCode.value,
  });
};

const dealSubtitle = deal => {
  return deal.primaryContact?.name || '';
};

const emitStageChange = (deal, stageId) => {
  const nextStageId = Number(stageId);

  if (!deal || Number(deal.stageId) === nextStageId) return;

  deal.stageId = nextStageId;
  emit('changeStage', { deal, stageId: nextStageId });
};

const handleColumnChange = (event, stageId) => {
  if (!event.added) return;

  const deal = boardColumns.value[Number(stageId)][event.added.newIndex];
  emitStageChange(deal, stageId);
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
  <div class="flex h-full min-h-0 flex-col">
    <div class="min-h-0 flex-1 overflow-x-auto overflow-y-hidden px-1 pb-2">
      <div class="mx-auto flex h-full w-max items-stretch gap-2 py-1">
        <section
          v-for="column in kanbanColumns"
          :key="column.stageId"
          class="crm-deal-board-column group/crm-column flex h-full min-h-0 w-[17rem] shrink-0 flex-col overflow-visible"
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
                {{ column.deals.length }}
              </span>
            </div>
            <div
              class="mt-3 h-1 overflow-hidden rounded-full bg-n-alpha-black2"
            >
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
            :disabled="!canManage"
            animation="180"
            class="flex min-h-0 flex-1 flex-col gap-3 overflow-y-auto px-3 pb-3 pt-1.5"
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
                    <h4
                      class="mb-0 truncate text-xs font-semibold text-n-slate-12"
                    >
                      {{ element.title }}
                    </h4>
                    <p class="mb-0 mt-0.5 text-[10px] text-n-slate-11">
                      {{
                        dealSubtitle(element) || $t('CRM.GENERAL.EMPTY_VALUE')
                      }}
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
