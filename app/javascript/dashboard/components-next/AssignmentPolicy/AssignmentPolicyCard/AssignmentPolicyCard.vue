<script setup>
import { computed } from 'vue';
import { useI18n } from 'vue-i18n';
import { getInboxIconByType } from 'dashboard/helper/inbox';

import Button from 'dashboard/components-next/button/Button.vue';
import CardLayout from 'dashboard/components-next/CardLayout.vue';
import CardPopover from '../components/CardPopover.vue';

const props = defineProps({
  id: { type: Number, required: true },
  name: { type: String, default: '' },
  description: { type: String, default: '' },
  assignmentOrder: { type: String, default: '' },
  conversationPriority: { type: String, default: '' },
  assignedInboxCount: { type: Number, default: 0 },
  assignmentDelayMinutes: { type: Number, default: 0 },
  maxOpenConversations: { type: Number, default: null },
  assignOnlineOnly: { type: Boolean, default: true },
  assignPendingConversations: { type: Boolean, default: false },
  monthlyNewClientQuota: { type: Number, default: null },
  stickyOwnerEnabled: { type: Boolean, default: false },
  stickyOwnerDurationDays: { type: Number, default: 30 },
  inboxes: { type: Array, default: () => [] },
  isFetchingInboxes: { type: Boolean, default: false },
});

const emit = defineEmits(['edit', 'delete', 'fetchInboxes']);

const { t } = useI18n();

const inboxes = computed(() => {
  return props.inboxes.map(inbox => {
    return {
      name: inbox.name,
      id: inbox.id,
      icon: getInboxIconByType(inbox.channelType, inbox.medium, 'line'),
    };
  });
});

const order = computed(() => {
  if (props.assignmentOrder === 'round_robin') {
    return t(
      'ASSIGNMENT_POLICY.AGENT_ASSIGNMENT_POLICY.FORM.ASSIGNMENT_ORDER.ROUND_ROBIN.LABEL'
    );
  }

  if (props.assignmentOrder === 'balanced') {
    return t(
      'ASSIGNMENT_POLICY.AGENT_ASSIGNMENT_POLICY.FORM.ASSIGNMENT_ORDER.BALANCED.LABEL'
    );
  }

  return '';
});

const priority = computed(() => {
  if (props.conversationPriority === 'earliest_created') {
    return t(
      'ASSIGNMENT_POLICY.AGENT_ASSIGNMENT_POLICY.FORM.ASSIGNMENT_PRIORITY.EARLIEST_CREATED.LABEL'
    );
  }

  if (props.conversationPriority === 'longest_waiting') {
    return t(
      'ASSIGNMENT_POLICY.AGENT_ASSIGNMENT_POLICY.FORM.ASSIGNMENT_PRIORITY.LONGEST_WAITING.LABEL'
    );
  }

  return '';
});

const loadSummary = computed(() => {
  const items = [];

  if (props.assignmentDelayMinutes > 0) {
    items.push(
      t('ASSIGNMENT_POLICY.AGENT_ASSIGNMENT_POLICY.INDEX.CARD.DELAY', {
        minutes: props.assignmentDelayMinutes,
      })
    );
  }

  if (props.maxOpenConversations) {
    items.push(
      t('ASSIGNMENT_POLICY.AGENT_ASSIGNMENT_POLICY.INDEX.CARD.MAX_OPEN', {
        count: props.maxOpenConversations,
      })
    );
  }

  if (props.assignOnlineOnly) {
    items.push(
      t('ASSIGNMENT_POLICY.AGENT_ASSIGNMENT_POLICY.INDEX.CARD.ONLINE_ONLY')
    );
  }

  if (props.assignPendingConversations) {
    items.push(
      t('ASSIGNMENT_POLICY.AGENT_ASSIGNMENT_POLICY.INDEX.CARD.ASSIGN_PENDING')
    );
  }

  if (props.monthlyNewClientQuota) {
    items.push(
      t('ASSIGNMENT_POLICY.AGENT_ASSIGNMENT_POLICY.INDEX.CARD.MONTHLY_QUOTA', {
        count: props.monthlyNewClientQuota,
      })
    );
  }

  if (props.stickyOwnerEnabled) {
    items.push(
      t('ASSIGNMENT_POLICY.AGENT_ASSIGNMENT_POLICY.INDEX.CARD.STICKY_OWNER', {
        days: props.stickyOwnerDurationDays,
      })
    );
  }

  return items;
});

const handleEdit = () => {
  emit('edit', props.id);
};

const handleDelete = () => {
  emit('delete', props.id);
};

const handleFetchInboxes = () => {
  if (props.inboxes?.length > 0) return;
  emit('fetchInboxes', props.id);
};
</script>

<template>
  <CardLayout class="[&>div]:px-5">
    <div class="flex flex-col gap-2 relative justify-between w-full">
      <div class="flex items-center gap-3 justify-between w-full">
        <div class="flex items-center gap-3">
          <h3 class="text-heading-2 text-n-slate-12 line-clamp-1">
            {{ name }}
          </h3>
          <CardPopover
            :title="
              t('ASSIGNMENT_POLICY.AGENT_ASSIGNMENT_POLICY.INDEX.CARD.POPOVER')
            "
            icon="i-lucide-inbox"
            :count="assignedInboxCount"
            :items="inboxes"
            :is-fetching="isFetchingInboxes"
            @fetch="handleFetchInboxes"
          />
        </div>
        <div class="flex items-center gap-2">
          <Button
            :label="
              t('ASSIGNMENT_POLICY.AGENT_ASSIGNMENT_POLICY.INDEX.CARD.EDIT')
            "
            sm
            slate
            link
            class="px-2"
            @click="handleEdit"
          />
          <div v-if="order" class="w-px h-2.5 bg-n-slate-5" />
          <Button icon="i-lucide-trash" sm slate ghost @click="handleDelete" />
        </div>
      </div>
      <p class="text-n-slate-11 text-body-para line-clamp-1 mb-0 py-1">
        {{ description }}
      </p>
      <div class="flex items-center gap-3 py-1.5">
        <span v-if="order" class="text-n-slate-11 text-body-para">
          {{
            `${t('ASSIGNMENT_POLICY.AGENT_ASSIGNMENT_POLICY.INDEX.CARD.ORDER')}:`
          }}
          <span class="text-n-slate-12">{{ order }}</span>
        </span>
        <div v-if="order" class="w-px h-3 bg-n-strong" />
        <span v-if="priority" class="text-n-slate-11 text-body-para">
          {{
            `${t('ASSIGNMENT_POLICY.AGENT_ASSIGNMENT_POLICY.INDEX.CARD.PRIORITY')}:`
          }}
          <span class="text-n-slate-12">{{ priority }}</span>
        </span>
      </div>
      <div v-if="loadSummary.length" class="flex flex-wrap gap-2 py-1">
        <span
          v-for="item in loadSummary"
          :key="item"
          class="rounded-full bg-n-alpha-2 px-2 py-0.5 text-xs font-medium text-n-slate-11"
        >
          {{ item }}
        </span>
      </div>
    </div>
  </CardLayout>
</template>
