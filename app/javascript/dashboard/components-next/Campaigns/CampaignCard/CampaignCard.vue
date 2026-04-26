<script setup>
import { computed } from 'vue';
import { useI18n } from 'vue-i18n';
import { useMessageFormatter } from 'shared/composables/useMessageFormatter';
import { getInboxIconByType } from 'dashboard/helper/inbox';
import { getProcessedTemplateParamEntries } from 'dashboard/helper/whatsappTemplateLibrary';

import CardLayout from 'dashboard/components-next/CardLayout.vue';
import Button from 'dashboard/components-next/button/Button.vue';
import LiveChatCampaignDetails from './LiveChatCampaignDetails.vue';
import SMSCampaignDetails from './SMSCampaignDetails.vue';

const props = defineProps({
  title: {
    type: String,
    default: '',
  },
  message: {
    type: String,
    default: '',
  },
  textMode: {
    type: String,
    default: '',
  },
  instructions: {
    type: String,
    default: '',
  },
  templateParams: {
    type: Object,
    default: null,
  },
  campaignType: {
    type: String,
    default: '',
  },
  isLiveChatType: {
    type: Boolean,
    default: false,
  },
  isEnabled: {
    type: Boolean,
    default: false,
  },
  status: {
    type: String,
    default: '',
  },
  sender: {
    type: Object,
    default: null,
  },
  aiSender: {
    type: Object,
    default: null,
  },
  inbox: {
    type: Object,
    default: null,
  },
  scheduledAt: {
    type: Number,
    default: 0,
  },
  showAnalytics: {
    type: Boolean,
    default: false,
  },
  latestRun: {
    type: Object,
    default: null,
  },
  isRetrying: {
    type: Boolean,
    default: false,
  },
  isCanceling: {
    type: Boolean,
    default: false,
  },
  isRestarting: {
    type: Boolean,
    default: false,
  },
  isResuming: {
    type: Boolean,
    default: false,
  },
});

const emit = defineEmits([
  'edit',
  'delete',
  'analytics',
  'retry',
  'cancel',
  'restart',
  'resume',
]);

const { locale, t } = useI18n();

const STATUS_COMPLETED = 'completed';
const STATUS_RUNNING = 'running';
const STATUS_FAILED = 'failed';
const STATUS_CANCELLED = 'cancelled';

const { formatMessage } = useMessageFormatter();

const resolvedIsLiveChatType = computed(() => {
  return props.isLiveChatType || props.campaignType === 'ongoing';
});

const isActive = computed(() =>
  resolvedIsLiveChatType.value
    ? props.isEnabled
    : ![STATUS_COMPLETED, STATUS_FAILED].includes(props.status)
);

const statusTextColor = computed(() => {
  if (resolvedIsLiveChatType.value) {
    return {
      'text-n-teal-11': isActive.value,
      'text-n-slate-12': !isActive.value,
    };
  }

  return {
    'text-n-teal-11': props.status === STATUS_RUNNING,
    'text-n-ruby-11': props.status === STATUS_FAILED,
    'text-n-slate-12': [
      STATUS_COMPLETED,
      STATUS_FAILED,
      STATUS_CANCELLED,
    ].includes(props.status),
    'text-n-amber-11': ![
      STATUS_COMPLETED,
      STATUS_RUNNING,
      STATUS_FAILED,
      STATUS_CANCELLED,
    ].includes(props.status),
  };
});

const campaignStatus = computed(() => {
  if (resolvedIsLiveChatType.value) {
    return props.isEnabled
      ? t('CAMPAIGN.LIVE_CHAT.CARD.STATUS.ENABLED')
      : t('CAMPAIGN.LIVE_CHAT.CARD.STATUS.DISABLED');
  }

  if (props.status === STATUS_RUNNING) {
    return t('CAMPAIGN.SMS.CARD.STATUS.RUNNING');
  }

  if (props.status === STATUS_FAILED) {
    return t('CAMPAIGN.SMS.CARD.STATUS.FAILED');
  }

  if (props.status === STATUS_CANCELLED) {
    return t('CAMPAIGN.SMS.CARD.STATUS.CANCELLED');
  }

  return props.status === STATUS_COMPLETED
    ? t('CAMPAIGN.SMS.CARD.STATUS.COMPLETED')
    : t('CAMPAIGN.SMS.CARD.STATUS.SCHEDULED');
});

const inboxName = computed(() => props.inbox?.name || '');

const inboxIcon = computed(() => {
  const { medium, channel_type: type } = props.inbox;
  return getInboxIconByType(type, medium);
});
const templateLabel = computed(() => {
  const templateName = String(props.templateParams?.name || '');
  if (!templateName) {
    return '';
  }

  return templateName
    .replace(/_/g, ' ')
    .replace(/\b\w/g, letter => letter.toUpperCase());
});
const allTemplateParamEntries = computed(() =>
  getProcessedTemplateParamEntries(props.templateParams)
);
const templateParamEntries = computed(() =>
  allTemplateParamEntries.value.slice(0, 4)
);
const previewText = computed(() => {
  if (props.message) {
    return props.message;
  }

  if (props.textMode === 'agent' || props.instructions) {
    return t('OUTBOUND_WORKSPACE.TOUCHES.AGENT_PREVIEW');
  }

  return '';
});
const hiddenTemplateParamCount = computed(() => {
  return Math.max(
    allTemplateParamEntries.value.length - templateParamEntries.value.length,
    0
  );
});

const latestRunStatusText = computed(() => {
  if (!props.latestRun) return '';

  if (props.latestRun.status === STATUS_RUNNING) {
    return t('CAMPAIGN.OUTBOUND.CARD.LATEST_RUN.STATUS.RUNNING');
  }

  if (props.latestRun.status === STATUS_FAILED) {
    return t('CAMPAIGN.OUTBOUND.CARD.LATEST_RUN.STATUS.FAILED');
  }

  if (props.latestRun.status === STATUS_CANCELLED) {
    return t('CAMPAIGN.OUTBOUND.CARD.LATEST_RUN.STATUS.CANCELLED');
  }

  return t('CAMPAIGN.OUTBOUND.CARD.LATEST_RUN.STATUS.COMPLETED');
});

const latestRunSummary = computed(() => {
  if (!props.latestRun) return '';

  return t('CAMPAIGN.OUTBOUND.CARD.LATEST_RUN.SUMMARY', {
    processed: props.latestRun.processed_count || 0,
    total: props.latestRun.total_count || 0,
  });
});

const latestRunTimeLabel = computed(() => {
  if (!props.latestRun) return '';

  return props.latestRun.status === STATUS_RUNNING
    ? t('CAMPAIGN.OUTBOUND.CARD.LATEST_RUN.TIME.STARTED')
    : t('CAMPAIGN.OUTBOUND.CARD.LATEST_RUN.TIME.COMPLETED');
});

const latestRunTimeValue = computed(() => {
  if (!props.latestRun) return '';

  const timestamp =
    props.latestRun.status === STATUS_RUNNING
      ? props.latestRun.started_at
      : props.latestRun.completed_at || props.latestRun.created_at;

  if (!timestamp) return '';

  return new Intl.DateTimeFormat(locale.value || 'en', {
    year: 'numeric',
    month: 'short',
    day: 'numeric',
    hour: '2-digit',
    minute: '2-digit',
    hour12: false,
  }).format(new Date(timestamp * 1000));
});

const latestRunCounters = computed(() => {
  if (!props.latestRun) return [];

  return [
    {
      key: 'successful',
      label: t('CAMPAIGN.OUTBOUND.CARD.LATEST_RUN.COUNTERS.SUCCESSFUL'),
      value: props.latestRun.successful_count || 0,
      classes: 'bg-n-teal-3 text-n-teal-11',
    },
    {
      key: 'failed',
      label: t('CAMPAIGN.OUTBOUND.CARD.LATEST_RUN.COUNTERS.FAILED'),
      value:
        (props.latestRun.failed_count || 0) +
        (props.latestRun.skipped_count || 0),
      classes: 'bg-n-ruby-3 text-n-ruby-11',
    },
  ];
});

const latestRunBadges = computed(() => {
  if (!props.latestRun) return [];

  return [
    props.latestRun.resume_run
      ? {
          key: 'resume',
          label: t('CAMPAIGN.OUTBOUND.CARD.LATEST_RUN.BADGES.RESUME'),
          classes: 'bg-n-slate-3 text-n-slate-11',
        }
      : null,
    props.latestRun.restart_run
      ? {
          key: 'restart',
          label: t('CAMPAIGN.OUTBOUND.CARD.LATEST_RUN.BADGES.RESTART'),
          classes: 'bg-n-blue-3 text-n-blue-11',
        }
      : null,
    props.latestRun.retry_source_run_id
      ? {
          key: 'retry-source',
          label: t('CAMPAIGN.OUTBOUND.CARD.LATEST_RUN.BADGES.RETRY_OF', {
            id: props.latestRun.retry_source_run_id,
          }),
          classes: 'bg-n-alpha-2 text-n-slate-11',
        }
      : null,
  ].filter(Boolean);
});

const latestRunTextColor = computed(() => ({
  'text-n-blue-11': props.latestRun?.status === STATUS_RUNNING,
  'text-n-ruby-11': props.latestRun?.status === STATUS_FAILED,
  'text-n-teal-11': props.latestRun?.status === STATUS_COMPLETED,
  'text-n-slate-11':
    props.latestRun?.status === STATUS_CANCELLED || !props.latestRun,
}));

const canRetryLatestRun = computed(() => {
  if (
    resolvedIsLiveChatType.value ||
    !props.latestRun ||
    props.latestRun.status === STATUS_RUNNING ||
    props.status === STATUS_CANCELLED
  ) {
    return false;
  }

  return (
    (props.latestRun.failed_count || 0) + (props.latestRun.skipped_count || 0) >
    0
  );
});

const canCancelCampaign = computed(
  () =>
    !resolvedIsLiveChatType.value &&
    ['active', STATUS_RUNNING].includes(props.status)
);

const canRestartCampaign = computed(
  () =>
    !resolvedIsLiveChatType.value &&
    [STATUS_FAILED, STATUS_CANCELLED].includes(props.status)
);

const canResumeCampaign = computed(
  () =>
    !resolvedIsLiveChatType.value &&
    [STATUS_FAILED, STATUS_CANCELLED].includes(props.status) &&
    (props.latestRun?.resumable_contacts_count || 0) > 0
);
</script>

<template>
  <CardLayout layout="row">
    <div class="flex flex-col items-start justify-between flex-1 min-w-0 gap-2">
      <div class="flex justify-between gap-3 w-fit">
        <span
          class="text-base font-medium capitalize text-n-slate-12 line-clamp-1"
        >
          {{ title }}
        </span>
        <span
          class="text-xs font-medium inline-flex items-center h-6 px-2 py-0.5 rounded-md bg-n-alpha-2"
          :class="statusTextColor"
        >
          {{ campaignStatus }}
        </span>
      </div>
      <div
        v-dompurify-html="formatMessage(previewText, false, false, false)"
        class="text-sm text-n-slate-11 line-clamp-1 [&>p]:mb-0 h-6"
      />
      <div
        v-if="templateLabel || templateParamEntries.length"
        class="flex flex-wrap items-center gap-2 min-h-5 text-xs"
      >
        <span
          v-if="templateLabel"
          class="inline-flex items-center rounded-md bg-n-iris-3 px-2 py-0.5 font-medium text-n-iris-11"
        >
          {{ templateLabel }}
        </span>
        <span
          v-for="entry in templateParamEntries"
          :key="entry.key"
          class="inline-flex max-w-[14rem] items-center gap-1 rounded-md bg-n-alpha-2 px-2 py-0.5 text-n-slate-11"
        >
          <span class="font-medium">{{ entry.label }}</span>
          <span class="truncate">{{ entry.value }}</span>
        </span>
        <span
          v-if="hiddenTemplateParamCount > 0"
          class="inline-flex items-center rounded-md bg-n-alpha-2 px-2 py-0.5 text-n-slate-11"
        >
          {{ `+${hiddenTemplateParamCount}` }}
        </span>
      </div>
      <div class="flex items-center w-full min-h-6 gap-2 overflow-hidden">
        <LiveChatCampaignDetails
          v-if="resolvedIsLiveChatType"
          :sender="sender"
          :inbox-name="inboxName"
          :inbox-icon="inboxIcon"
        />
        <SMSCampaignDetails
          v-else
          :sender="sender"
          :ai-sender="aiSender"
          :inbox-name="inboxName"
          :inbox-icon="inboxIcon"
          :scheduled-at="scheduledAt"
        />
      </div>
      <div
        v-if="!resolvedIsLiveChatType && latestRun"
        class="flex items-center gap-2 min-h-5 text-xs"
      >
        <span class="font-medium text-n-slate-11">
          {{ t('CAMPAIGN.OUTBOUND.CARD.LATEST_RUN.TITLE') }}
        </span>
        <span class="capitalize" :class="latestRunTextColor">
          {{ latestRunStatusText }}
        </span>
        <span class="text-n-slate-11">
          {{ latestRunSummary }}
        </span>
      </div>
      <div
        v-if="!resolvedIsLiveChatType && latestRunBadges.length"
        class="flex flex-wrap items-center gap-2 min-h-5 text-xs"
      >
        <span
          v-for="badge in latestRunBadges"
          :key="badge.key"
          class="inline-flex items-center rounded-md px-2 py-0.5 font-medium"
          :class="badge.classes"
        >
          {{ badge.label }}
        </span>
      </div>
      <div
        v-if="!resolvedIsLiveChatType && latestRun"
        class="flex items-center gap-2 min-h-5 text-xs"
      >
        <span
          v-for="counter in latestRunCounters"
          :key="counter.key"
          class="inline-flex items-center gap-1 rounded-md px-2 py-0.5 font-medium"
          :class="counter.classes"
        >
          <span>{{ counter.label }}</span>
          <span>{{ counter.value }}</span>
        </span>
      </div>
      <div
        v-if="!resolvedIsLiveChatType && latestRunTimeValue"
        class="flex items-center gap-2 min-h-5 text-xs text-n-slate-11"
      >
        <span class="font-medium">
          {{ latestRunTimeLabel }}
        </span>
        <span>
          {{ latestRunTimeValue }}
        </span>
      </div>
    </div>
    <div class="flex shrink-0 flex-wrap items-center justify-end gap-2 pl-2">
      <Button
        v-if="canResumeCampaign"
        variant="faded"
        size="sm"
        color="slate"
        icon="i-lucide-skip-forward"
        :is-loading="isResuming"
        :disabled="isResuming || isRestarting || isCanceling || isRetrying"
        :title="t('CAMPAIGN.OUTBOUND.CARD.RESUME_CAMPAIGN')"
        @click="emit('resume')"
      />
      <Button
        v-if="canRestartCampaign"
        variant="faded"
        size="sm"
        color="blue"
        icon="i-lucide-play"
        :is-loading="isRestarting"
        :disabled="isRestarting || isResuming || isCanceling || isRetrying"
        :title="t('CAMPAIGN.OUTBOUND.CARD.RESTART_CAMPAIGN')"
        @click="emit('restart')"
      />
      <Button
        v-if="canCancelCampaign"
        variant="faded"
        size="sm"
        color="ruby"
        icon="i-lucide-circle-stop"
        :is-loading="isCanceling"
        :disabled="isCanceling || isRetrying"
        :title="t('CAMPAIGN.OUTBOUND.CARD.CANCEL_CAMPAIGN')"
        @click="emit('cancel')"
      />
      <Button
        v-if="canRetryLatestRun"
        variant="faded"
        size="sm"
        color="blue"
        icon="i-lucide-rotate-ccw"
        :is-loading="isRetrying"
        :disabled="isRetrying"
        :title="t('CAMPAIGN.OUTBOUND.CARD.LATEST_RUN.RETRY')"
        @click="emit('retry')"
      />
      <Button
        v-if="resolvedIsLiveChatType"
        variant="faded"
        size="sm"
        color="slate"
        icon="i-lucide-sliders-vertical"
        @click="emit('edit')"
      />
      <Button
        v-if="showAnalytics"
        variant="faded"
        size="sm"
        color="slate"
        icon="i-lucide-chart-column"
        @click="emit('analytics')"
      />
      <Button
        variant="faded"
        color="ruby"
        size="sm"
        icon="i-lucide-trash"
        @click="emit('delete')"
      />
    </div>
  </CardLayout>
</template>
