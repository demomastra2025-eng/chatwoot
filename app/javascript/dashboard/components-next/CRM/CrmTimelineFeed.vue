<script setup>
import { computed, ref } from 'vue';
import { formatDistanceToNow } from 'date-fns';
import { useI18n } from 'vue-i18n';

import Button from 'dashboard/components-next/button/Button.vue';
import Icon from 'dashboard/components-next/icon/Icon.vue';
import TextArea from 'dashboard/components-next/textarea/TextArea.vue';

const props = defineProps({
  canManageComments: {
    type: Boolean,
    default: false,
  },
  emptyMessage: {
    type: String,
    default: '',
  },
  isLoading: {
    type: Boolean,
    default: false,
  },
  isSavingComment: {
    type: Boolean,
    default: false,
  },
  items: {
    type: Array,
    default: () => [],
  },
});

const emit = defineEmits(['createComment', 'deleteComment']);

const { t } = useI18n();

const commentBody = ref('');
const isExpanded = ref(false);

const eventIconByType = {
  deal_archived: 'i-lucide-archive',
  deal_created: 'i-lucide-plus',
  deal_stage_changed: 'i-lucide-arrow-right-left',
  deal_unarchived: 'i-lucide-archive-restore',
  deal_updated: 'i-lucide-pencil-line',
  task_archived: 'i-lucide-archive',
  task_created: 'i-lucide-plus',
  task_status_changed: 'i-lucide-arrow-right-left',
  task_unarchived: 'i-lucide-archive-restore',
  task_updated: 'i-lucide-pencil-line',
};

const sortedItems = computed(() => {
  return [...props.items].sort((left, right) => {
    return new Date(right.occurredAt || 0) - new Date(left.occurredAt || 0);
  });
});

const eventLabelByType = computed(() => ({
  deal_archived: t('CRM.TIMELINE.EVENT_LABELS.DEAL_ARCHIVED'),
  deal_created: t('CRM.TIMELINE.EVENT_LABELS.DEAL_CREATED'),
  deal_stage_changed: t('CRM.TIMELINE.EVENT_LABELS.DEAL_STAGE_CHANGED'),
  deal_unarchived: t('CRM.TIMELINE.EVENT_LABELS.DEAL_UNARCHIVED'),
  deal_updated: t('CRM.TIMELINE.EVENT_LABELS.DEAL_UPDATED'),
  task_archived: t('CRM.TIMELINE.EVENT_LABELS.TASK_ARCHIVED'),
  task_created: t('CRM.TIMELINE.EVENT_LABELS.TASK_CREATED'),
  task_status_changed: t('CRM.TIMELINE.EVENT_LABELS.TASK_STATUS_CHANGED'),
  task_unarchived: t('CRM.TIMELINE.EVENT_LABELS.TASK_UNARCHIVED'),
  task_updated: t('CRM.TIMELINE.EVENT_LABELS.TASK_UPDATED'),
}));

const timelineSummary = computed(() => {
  if (props.isLoading) return t('CRM.TIMELINE.LOADING');
  if (!sortedItems.value.length) {
    return props.emptyMessage || t('CRM.TIMELINE.EMPTY');
  }

  return t('CRM.TIMELINE.ACTIVITY_COUNT', {
    count: sortedItems.value.length,
  });
});

const formatRelativeTime = value => {
  if (!value) return '';
  return formatDistanceToNow(new Date(value), { addSuffix: true });
};

const eventLabel = eventType => {
  const label = eventLabelByType.value[eventType];
  if (label) return label;

  return String(eventType || '')
    .replace(/_/g, ' ')
    .replace(/\b\w/g, letter => letter.toUpperCase());
};

const eventDescription = item => {
  const meta = item.payload?.meta || {};
  if (item.payload?.eventType === 'deal_stage_changed') {
    const transitionReason = meta.transitionReason || meta.transition_reason;
    const closingReasons = meta.closingReasons || meta.closing_reasons;

    if (transitionReason) {
      return t('CRM.TIMELINE.TRANSITION_REASON', {
        reason: transitionReason,
      });
    }

    if (Array.isArray(closingReasons) && closingReasons.length) {
      return t('CRM.TIMELINE.CLOSING_REASONS', {
        reasons: closingReasons.join(', '),
      });
    }
  }

  const changesCount = Object.keys(meta.changes || {}).length;
  if (changesCount) {
    return t('CRM.TIMELINE.FIELD_CHANGES', { count: changesCount });
  }

  return t('CRM.TIMELINE.EVENT_RECORDED');
};

const itemIcon = item => {
  if (item.itemType === 'comment') return 'i-lucide-message-square-text';
  if (item.itemType === 'conversation') return 'i-lucide-messages-square';

  return eventIconByType[item.payload?.eventType] || 'i-lucide-activity';
};

const itemMarkerClass = item => {
  if (item.itemType === 'comment') {
    return 'bg-n-blue-3 text-n-blue-11 ring-n-blue-4/60';
  }

  if (item.itemType === 'conversation') {
    return 'bg-n-teal-3 text-n-teal-11 ring-n-teal-4/60';
  }

  if (
    ['deal_stage_changed', 'task_status_changed'].includes(
      item.payload?.eventType
    )
  ) {
    return 'bg-n-amber-3 text-n-amber-11 ring-n-amber-4/60';
  }

  return 'bg-n-slate-3 text-n-slate-11 ring-n-slate-4/60';
};

const itemTitle = item => {
  if (item.itemType === 'comment') {
    return item.payload.user?.name || t('CRM.TIMELINE.COMMENT');
  }

  if (item.itemType === 'conversation') {
    return t('CRM.TIMELINE.CONVERSATION', {
      id: item.payload.displayId || item.payload.id,
    });
  }

  return eventLabel(item.payload?.eventType);
};

const itemBody = item => {
  if (item.itemType === 'comment') return item.payload.body;

  if (item.itemType === 'conversation') {
    return item.payload.contact?.name || t('CRM.TIMELINE.UNKNOWN_CONTACT');
  }

  return eventDescription(item);
};

const itemMeta = item => {
  if (item.itemType === 'conversation') return item.payload.status;
  return '';
};

const submitComment = () => {
  const body = commentBody.value.trim();
  if (!body) return;

  emit('createComment', body);
  commentBody.value = '';
};
</script>

<template>
  <section
    class="overflow-hidden rounded-2xl border border-n-weak bg-n-solid-1 shadow-sm"
  >
    <button
      type="button"
      class="group flex w-full items-center justify-between gap-3 px-4 py-3 text-left transition-colors hover:bg-n-alpha-black2"
      :aria-expanded="isExpanded"
      @click="isExpanded = !isExpanded"
    >
      <span class="flex min-w-0 items-center gap-3">
        <span
          class="flex size-8 shrink-0 items-center justify-center rounded-xl bg-n-slate-3 text-n-slate-11"
        >
          <Icon icon="i-lucide-history" class="size-4" />
        </span>
        <span class="grid min-w-0 gap-0.5">
          <span class="truncate text-sm font-medium text-n-slate-12">
            {{ t('CRM.TIMELINE.TITLE') }}
          </span>
          <span class="truncate text-xs text-n-slate-10">
            {{ timelineSummary }}
          </span>
        </span>
      </span>

      <span class="flex shrink-0 items-center gap-2">
        <span
          v-if="sortedItems.length"
          class="rounded-full bg-n-alpha-black2 px-2 py-0.5 text-[11px] font-medium leading-4 text-n-slate-11 ring-1 ring-n-weak"
        >
          {{ sortedItems.length }}
        </span>
        <Icon
          :icon="isExpanded ? 'i-lucide-chevron-up' : 'i-lucide-chevron-down'"
          class="size-4 text-n-slate-10 transition-transform group-hover:text-n-slate-12"
        />
      </span>
    </button>

    <div v-show="isExpanded" class="border-t border-n-weak bg-n-solid-2">
      <div v-if="canManageComments" class="grid gap-2 px-4 py-3">
        <TextArea
          :label="t('CRM.TIMELINE.ADD_COMMENT')"
          :model-value="commentBody"
          :placeholder="t('CRM.TIMELINE.COMMENT_PLACEHOLDER')"
          auto-height
          custom-text-area-wrapper-class="!rounded-md !border-n-weak !bg-n-alpha-black2 !px-3 !py-2 hover:!border-n-slate-6"
          min-height="3rem"
          max-height="none"
          @update:model-value="commentBody = $event"
        />
        <div class="flex justify-end">
          <Button
            size="sm"
            :disabled="!commentBody.trim()"
            :is-loading="isSavingComment"
            :label="t('CRM.TIMELINE.POST_COMMENT')"
            @click="submitComment"
          />
        </div>
      </div>

      <div
        v-if="isLoading"
        class="px-4 py-6 text-center text-sm text-n-slate-11"
      >
        {{ t('CRM.TIMELINE.LOADING') }}
      </div>

      <div
        v-else-if="sortedItems.length === 0"
        class="px-4 py-6 text-center text-sm text-n-slate-11"
      >
        {{ emptyMessage }}
      </div>

      <ol v-else class="grid gap-0 px-4 py-3">
        <li
          v-for="(item, index) in sortedItems"
          :key="`${item.itemType}-${item.payload.id}-${item.occurredAt}`"
          class="grid grid-cols-[1.5rem_minmax(0,1fr)] gap-3"
        >
          <div class="relative flex justify-center">
            <span
              v-if="index < sortedItems.length - 1"
              class="absolute bottom-[-0.75rem] top-7 w-px bg-n-weak"
            />
            <span
              class="relative z-10 flex size-7 items-center justify-center rounded-full ring-1"
              :class="itemMarkerClass(item)"
            >
              <Icon :icon="itemIcon(item)" class="size-3.5" />
            </span>
          </div>

          <article
            class="min-w-0"
            :class="{ 'pb-6': index < sortedItems.length - 1 }"
          >
            <div class="flex min-w-0 items-start justify-between gap-3">
              <div class="grid min-w-0 gap-0">
                <h4
                  class="mb-0 truncate text-sm font-medium leading-5 text-n-slate-12"
                >
                  {{ itemTitle(item) }}
                </h4>
                <p class="mb-0 text-xs leading-4 text-n-slate-10">
                  {{ formatRelativeTime(item.occurredAt) }}
                </p>
              </div>

              <Button
                v-if="item.itemType === 'comment' && canManageComments"
                size="sm"
                color="slate"
                variant="ghost"
                icon="i-lucide-trash"
                @click="emit('deleteComment', item.payload)"
              />
            </div>

            <p
              v-if="itemBody(item)"
              class="mb-0 mt-1 whitespace-pre-wrap text-sm leading-4 text-n-slate-11"
            >
              {{ itemBody(item) }}
            </p>

            <p
              v-if="itemMeta(item)"
              class="mb-0 mt-0.5 text-xs capitalize leading-4 text-n-slate-10"
            >
              {{ itemMeta(item) }}
            </p>
          </article>
        </li>
      </ol>
    </div>
  </section>
</template>
