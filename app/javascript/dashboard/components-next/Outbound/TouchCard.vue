<script setup>
import { computed } from 'vue';
import { useI18n } from 'vue-i18n';
import { messageStamp } from 'shared/helpers/timeHelper';
import { getInboxIconByType } from 'dashboard/helper/inbox';

import CardLayout from 'dashboard/components-next/CardLayout.vue';
import Button from 'dashboard/components-next/button/Button.vue';
import Icon from 'dashboard/components-next/icon/Icon.vue';

const props = defineProps({
  isMutating: {
    type: Boolean,
    default: false,
  },
  showActions: {
    type: Boolean,
    default: true,
  },
  touch: {
    type: Object,
    required: true,
  },
});

const emit = defineEmits(['analytics', 'approve', 'cancel', 'delete', 'edit']);

const { t } = useI18n();

const statusText = computed(() => {
  switch (props.touch.status) {
    case 'pending':
      return t('OUTBOUND_WORKSPACE.TOUCHES.STATUS.PENDING');
    case 'processing':
      return t('OUTBOUND_WORKSPACE.TOUCHES.STATUS.PROCESSING');
    case 'completed':
      return t('OUTBOUND_WORKSPACE.TOUCHES.STATUS.COMPLETED');
    case 'cancelled':
      return t('OUTBOUND_WORKSPACE.TOUCHES.STATUS.CANCELLED');
    case 'failed':
      return t('OUTBOUND_WORKSPACE.TOUCHES.STATUS.FAILED');
    case 'draft':
    default:
      return t('OUTBOUND_WORKSPACE.TOUCHES.STATUS.DRAFT');
  }
});

const statusClass = computed(() => {
  return (
    {
      draft: 'bg-n-alpha-2 text-n-slate-11',
      pending: 'bg-n-brand/10 text-n-brand',
      processing: 'bg-n-amber-9/10 text-n-amber-11',
      completed: 'bg-n-teal-9/10 text-n-teal-11',
      cancelled: 'bg-n-slate-9/10 text-n-slate-11',
      failed: 'bg-n-ruby-9/10 text-n-ruby-11',
    }[props.touch.status] || 'bg-n-alpha-2 text-n-slate-11'
  );
});

const inbox = computed(() => props.touch.target?.inbox || null);
const inboxName = computed(() => inbox.value?.name || '—');
const inboxIcon = computed(() => {
  if (!inbox.value) return '';

  return getInboxIconByType(inbox.value.channel_type, inbox.value.medium);
});

const templateLabel = computed(() => {
  const templateName = String(props.touch.template_params?.name || '');
  if (!templateName) return '';

  return templateName
    .replace(/_/g, ' ')
    .replace(/\b\w/g, letter => letter.toUpperCase());
});

const recipientTitle = computed(() => {
  if (props.touch.target?.contact?.name) {
    return props.touch.target.contact.name;
  }

  if (props.touch.target?.contact_id) {
    return `#${props.touch.target.contact_id}`;
  }

  return props.touch.remindable?.title || '—';
});

const contactIdentifier = computed(
  () => props.touch.target?.contact?.identifier || ''
);

const remindableLabel = computed(() => {
  const remindableType = String(props.touch.remindable?.type || '')
    .replace(/^Crm::/, '')
    .replace(/^Scheduling::/, '');

  switch (remindableType) {
    case 'Conversation':
      return t('OUTBOUND_WORKSPACE.TOUCHES.ENTITY_KINDS.CONVERSATION');
    case 'Deal':
      return t('OUTBOUND_WORKSPACE.TOUCHES.ENTITY_KINDS.DEAL');
    case 'Task':
      return t('OUTBOUND_WORKSPACE.TOUCHES.ENTITY_KINDS.TASK');
    case 'Appointment':
      return t('OUTBOUND_WORKSPACE.TOUCHES.ENTITY_KINDS.APPOINTMENT');
    default:
      return props.touch.remindable?.title || '';
  }
});

const repeatText = computed(() => {
  switch (props.touch.repeat_mode) {
    case 'daily':
      return t('OUTBOUND_WORKSPACE.TOUCHES.REPEAT.DAILY');
    case 'weekly':
      return t('OUTBOUND_WORKSPACE.TOUCHES.REPEAT.WEEKLY');
    case 'weekdays':
      return t('OUTBOUND_WORKSPACE.TOUCHES.REPEAT.WEEKDAYS');
    case 'monthly':
      return t('OUTBOUND_WORKSPACE.TOUCHES.REPEAT.MONTHLY');
    case 'once':
    default:
      return t('OUTBOUND_WORKSPACE.TOUCHES.REPEAT.ONCE');
  }
});

const timingText = computed(() => {
  if (props.touch.scheduled_at) {
    return messageStamp(new Date(props.touch.scheduled_at), 'LLL d, h:mm a');
  }

  const minutes = Math.round((props.touch.relative_offset_seconds || 0) / 60);
  if (!minutes) {
    return t('OUTBOUND_WORKSPACE.TOUCHES.TIMING.AT_ANCHOR');
  }

  if (minutes > 0) {
    return t('OUTBOUND_WORKSPACE.TOUCHES.TIMING.AFTER_MINUTES', {
      count: minutes,
    });
  }

  return t('OUTBOUND_WORKSPACE.TOUCHES.TIMING.BEFORE_MINUTES', {
    count: Math.abs(minutes),
  });
});

const canEdit = computed(() =>
  ['draft', 'pending', 'failed', 'cancelled'].includes(props.touch.status)
);
const canApprove = computed(() => props.touch.status === 'draft');
const canCancel = computed(() =>
  ['draft', 'pending', 'processing'].includes(props.touch.status)
);
const canDelete = computed(() =>
  ['draft', 'pending', 'failed', 'cancelled'].includes(props.touch.status)
);
</script>

<template>
  <CardLayout layout="row" compact>
    <div class="flex min-w-0 flex-1 flex-col items-start justify-between gap-1">
      <div class="flex min-w-0 w-full items-center gap-2 overflow-hidden">
        <span
          class="min-w-0 max-w-[10rem] truncate text-sm font-medium text-n-slate-12 sm:max-w-[14rem] xl:max-w-[18rem]"
        >
          {{ recipientTitle }}
        </span>
        <span v-if="remindableLabel" class="shrink-0 text-xs text-n-slate-10">
          {{ remindableLabel }}
        </span>
        <span
          class="inline-flex shrink-0 items-center rounded-md bg-n-alpha-2 px-2 py-0.5 text-xs text-n-slate-11"
        >
          {{ repeatText }}
        </span>
        <span
          v-if="templateLabel"
          class="inline-flex shrink-0 items-center rounded-md bg-n-iris-3 px-2 py-0.5 text-xs font-medium text-n-iris-11"
        >
          {{ templateLabel }}
        </span>
      </div>

      <div class="flex min-h-5 w-full items-center gap-2 overflow-hidden">
        <span
          class="inline-flex shrink-0 items-center rounded-md px-1.5 py-0.5 text-xs font-medium"
          :class="statusClass"
        >
          {{ statusText }}
        </span>
        <span v-if="contactIdentifier" class="truncate text-xs text-n-slate-10">
          {{ contactIdentifier }}
        </span>
        <span class="shrink-0 text-xs text-n-slate-11 whitespace-nowrap">
          {{ t('CAMPAIGN.SMS.CARD.CAMPAIGN_DETAILS.SENT_FROM') }}
        </span>
        <div class="flex shrink-0 items-center gap-1.5">
          <Icon
            v-if="inboxIcon"
            :icon="inboxIcon"
            class="size-3 shrink-0 text-n-slate-12"
          />
          <span class="text-xs font-medium text-n-slate-12">
            {{ inboxName }}
          </span>
        </div>
        <span class="shrink-0 text-xs text-n-slate-11 whitespace-nowrap">
          {{ t('CAMPAIGN.SMS.CARD.CAMPAIGN_DETAILS.ON') }}
        </span>
        <span class="flex-1 truncate text-xs font-medium text-n-slate-12">
          {{ timingText }}
        </span>
      </div>
    </div>

    <div
      v-if="showActions"
      class="flex shrink-0 flex-wrap items-center justify-end gap-1.5 pl-2"
    >
      <Button
        v-if="canEdit"
        variant="faded"
        size="xs"
        color="slate"
        icon="i-lucide-sliders-horizontal"
        :disabled="isMutating"
        :title="$t('OUTBOUND_WORKSPACE.TOUCH_EDITOR.EDIT')"
        @click="emit('edit', touch)"
      />
      <Button
        variant="faded"
        size="xs"
        color="slate"
        icon="i-lucide-chart-column"
        :disabled="isMutating"
        :title="$t('OUTBOUND_WORKSPACE.TOUCHES.ANALYTICS.TITLE')"
        @click="emit('analytics', touch)"
      />
      <Button
        v-if="canApprove"
        variant="faded"
        size="xs"
        color="blue"
        icon="i-lucide-check"
        :is-loading="isMutating"
        :disabled="isMutating"
        :title="$t('OUTBOUND_WORKSPACE.TOUCHES.ALL.APPROVE')"
        @click="emit('approve', touch)"
      />
      <Button
        v-if="canCancel"
        variant="faded"
        size="xs"
        color="ruby"
        icon="i-lucide-circle-stop"
        :is-loading="isMutating"
        :disabled="isMutating"
        :title="$t('OUTBOUND_WORKSPACE.TOUCHES.ALL.CANCEL')"
        @click="emit('cancel', touch)"
      />
      <Button
        v-if="canDelete"
        variant="faded"
        size="xs"
        color="ruby"
        icon="i-lucide-trash"
        :disabled="isMutating"
        :title="$t('OUTBOUND_WORKSPACE.TOUCHES.CONFIRM_DELETE.CONFIRM')"
        @click="emit('delete', touch)"
      />
    </div>
  </CardLayout>
</template>
