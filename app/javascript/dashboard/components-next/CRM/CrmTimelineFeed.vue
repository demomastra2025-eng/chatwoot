<script setup>
import { computed, ref } from 'vue';
import { formatDistanceToNow } from 'date-fns';

import Button from 'dashboard/components-next/button/Button.vue';
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

const commentBody = ref('');

const sortedItems = computed(() => {
  return [...props.items].sort((left, right) => {
    return new Date(right.occurredAt) - new Date(left.occurredAt);
  });
});

const formatRelativeTime = value => {
  if (!value) return '';
  return formatDistanceToNow(new Date(value), { addSuffix: true });
};

const eventLabel = eventType => {
  return String(eventType || '')
    .replace(/_/g, ' ')
    .replace(/\b\w/g, letter => letter.toUpperCase());
};

const eventDescription = item => {
  const changesCount = Object.keys(item.payload?.meta?.changes || {}).length;
  if (changesCount) {
    return `${changesCount} field${changesCount === 1 ? '' : 's'} changed`;
  }

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
  <div class="grid gap-4">
    <div v-if="canManageComments" class="grid gap-3 px-4 py-4">
      <TextArea
        :label="$t('CRM.TIMELINE.ADD_COMMENT')"
        :model-value="commentBody"
        :placeholder="$t('CRM.TIMELINE.COMMENT_PLACEHOLDER')"
        auto-height
        @update:model-value="commentBody = $event"
      />
      <div class="flex justify-end">
        <Button
          size="sm"
          :disabled="!commentBody.trim()"
          :is-loading="isSavingComment"
          :label="$t('CRM.TIMELINE.POST_COMMENT')"
          @click="submitComment"
        />
      </div>
    </div>

    <div
      v-if="isLoading"
      class="rounded-2xl bg-n-alpha-black2 px-4 py-8 text-center text-sm text-n-slate-11 outline outline-1 outline-n-weak"
    >
      {{ $t('CRM.TIMELINE.LOADING') }}
    </div>

    <div
      v-else-if="sortedItems.length === 0"
      class="rounded-2xl bg-n-alpha-black2 px-4 py-8 text-center text-sm text-n-slate-11 outline outline-1 outline-n-weak"
    >
      {{ emptyMessage }}
    </div>

    <div v-else class="grid gap-3">
      <article
        v-for="item in sortedItems"
        :key="`${item.itemType}-${item.payload.id}-${item.occurredAt}`"
        class="grid gap-2 rounded-2xl bg-n-solid-2 px-4 py-3 outline outline-1 outline-n-container shadow-sm"
      >
        <div class="flex items-start justify-between gap-3">
          <div class="grid gap-1">
            <h4 class="mb-0 text-sm font-semibold text-n-slate-12">
              <template v-if="item.itemType === 'comment'">
                {{ item.payload.user?.name || $t('CRM.TIMELINE.COMMENT') }}
              </template>
              <template v-else-if="item.itemType === 'conversation'">
                {{
                  $t('CRM.TIMELINE.CONVERSATION', {
                    id: item.payload.displayId || item.payload.id,
                  })
                }}
              </template>
              <template v-else>
                {{ eventLabel(item.payload.eventType) }}
              </template>
            </h4>
            <p class="mb-0 text-xs text-n-slate-11">
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
          v-if="item.itemType === 'comment'"
          class="mb-0 whitespace-pre-wrap text-sm text-n-slate-12"
        >
          {{ item.payload.body }}
        </p>

        <div
          v-else-if="item.itemType === 'conversation'"
          class="grid gap-1 text-sm text-n-slate-12"
        >
          <p class="mb-0">
            {{
              item.payload.contact?.name || $t('CRM.TIMELINE.UNKNOWN_CONTACT')
            }}
          </p>
          <p class="mb-0 text-xs text-n-slate-11">
            {{ item.payload.status }}
          </p>
        </div>

        <p v-else class="mb-0 text-sm text-n-slate-12">
          {{ eventDescription(item) || $t('CRM.TIMELINE.EVENT_RECORDED') }}
        </p>
      </article>
    </div>
  </div>
</template>
