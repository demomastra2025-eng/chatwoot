<script setup>
import { computed } from 'vue';
import { useI18n } from 'vue-i18n';
import { messageTimestamp } from 'shared/helpers/timeHelper';

import MessageStatus from './MessageStatus.vue';
import Icon from 'next/icon/Icon.vue';
import Label from 'dashboard/components-next/label/Label.vue';
import { useInbox } from 'dashboard/composables/useInbox';
import { useMessageContext } from './provider.js';
import { useAudioPlaybackState } from './audioPlaybackState';

import { ATTACHMENT_TYPES, MESSAGE_STATUS, MESSAGE_TYPES } from './constants';

const {
  isAFacebookInbox,
  isALineChannel,
  isAPIInbox,
  isASmsInbox,
  isATelegramChannel,
  isATelegramPersonalChannel,
  isATwilioChannel,
  isAWebWidgetInbox,
  isAWhatsAppChannel,
  isAWhatsAppWebChannel,
  isAnEmailChannel,
  isAnInstagramChannel,
  isATiktokChannel,
} = useInbox();

const {
  status,
  isPrivate,
  createdAt,
  sourceId,
  messageType,
  additionalAttributes,
  contentAttributes,
  attachments,
  orientation,
} = useMessageContext();
const { t } = useI18n();

const readableTime = computed(() =>
  messageTimestamp(createdAt.value, 'LLL d, h:mm a')
);

const formatAgentName = agentName => {
  if (!agentName) return '';

  let normalized = String(agentName).trim();
  if (!normalized) return '';

  normalized = normalized.replace(/^scenario_(?:draft_)?/, '');
  normalized = normalized.replace(/^\d+_/, '');
  normalized = normalized.replace(/_agent$/, '');

  return normalized
    .split('_')
    .filter(Boolean)
    .map(segment => segment.charAt(0).toUpperCase() + segment.slice(1))
    .join(' ');
};

const subagentName = computed(
  () =>
    formatAgentName(additionalAttributes.value?.agentName) ||
    formatAgentName(additionalAttributes.value?.agent_name)
);
const isAiVoiceTranscriptTurn = computed(
  () => contentAttributes.value?.data?.type === 'ai_voice_transcript_turn'
);

const showStatusIndicator = computed(() => {
  if (isPrivate.value) return false;
  if (isAiVoiceTranscriptTurn.value) return false;
  // Don't show status for failed messages, we already show error message
  if (status.value === MESSAGE_STATUS.FAILED) return false;
  // Don't show status for deleted messages
  if (contentAttributes.value?.deleted) return false;

  if (messageType.value === MESSAGE_TYPES.OUTGOING) return true;
  if (messageType.value === MESSAGE_TYPES.TEMPLATE) return true;

  return false;
});

const isSent = computed(() => {
  if (!showStatusIndicator.value) return false;

  // Messages will be marked as sent for the Email channel if they have a source ID.
  if (isAnEmailChannel.value) return !!sourceId.value;

  if (
    isAWhatsAppChannel.value ||
    isAWhatsAppWebChannel.value ||
    isATwilioChannel.value ||
    isAFacebookInbox.value ||
    isASmsInbox.value ||
    isATelegramChannel.value ||
    isATelegramPersonalChannel.value ||
    isAnInstagramChannel.value ||
    isATiktokChannel.value
  ) {
    return sourceId.value && status.value === MESSAGE_STATUS.SENT;
  }

  // API inbox messages use real sent/delivered/read status values from the external system.
  if (isAPIInbox.value) return status.value === MESSAGE_STATUS.SENT;

  // All messages will be mark as sent for the Line channel, as there is no source ID.
  if (isALineChannel.value) return true;

  return false;
});

const isDelivered = computed(() => {
  if (!showStatusIndicator.value) return false;

  if (
    isAWhatsAppChannel.value ||
    isAWhatsAppWebChannel.value ||
    isATwilioChannel.value ||
    isASmsInbox.value ||
    isAFacebookInbox.value ||
    isATelegramPersonalChannel.value ||
    isAnInstagramChannel.value ||
    isATiktokChannel.value
  ) {
    return sourceId.value && status.value === MESSAGE_STATUS.DELIVERED;
  }
  // API inbox messages use real delivered status from the external system.
  if (isAPIInbox.value) return status.value === MESSAGE_STATUS.DELIVERED;
  // All messages marked as delivered for the web widget inbox once they are sent.
  if (isAWebWidgetInbox.value) {
    return status.value === MESSAGE_STATUS.SENT;
  }
  if (isALineChannel.value) {
    return status.value === MESSAGE_STATUS.DELIVERED;
  }

  return false;
});

const isRead = computed(() => {
  if (!showStatusIndicator.value) return false;

  if (
    isAWhatsAppChannel.value ||
    isAWhatsAppWebChannel.value ||
    isATwilioChannel.value ||
    isAFacebookInbox.value ||
    isATelegramPersonalChannel.value ||
    isAnInstagramChannel.value ||
    isATiktokChannel.value
  ) {
    return sourceId.value && status.value === MESSAGE_STATUS.READ;
  }

  if (isAWebWidgetInbox.value || isAPIInbox.value) {
    return status.value === MESSAGE_STATUS.READ;
  }

  return false;
});

const statusToShow = computed(() => {
  if (isRead.value) return MESSAGE_STATUS.READ;
  if (isDelivered.value) return MESSAGE_STATUS.DELIVERED;
  if (isSent.value) return MESSAGE_STATUS.SENT;

  return MESSAGE_STATUS.PROGRESS;
});

const isCampaignMessage = computed(
  () => !!additionalAttributes.value?.campaignId
);
const isDelayedMessage = computed(() => {
  return !!(
    additionalAttributes.value?.touchId ||
    additionalAttributes.value?.touch_id ||
    additionalAttributes.value?.touchSource === 'touch' ||
    additionalAttributes.value?.touch_source === 'touch'
  );
});

const isEdited = computed(() => !!contentAttributes.value?.edited);

const firstAudioAttachmentId = computed(() => {
  const audioAttachments = Array.isArray(attachments.value)
    ? attachments.value
    : [];
  const firstAudioAttachment = audioAttachments.find(
    attachment =>
      attachment.fileType === ATTACHMENT_TYPES.AUDIO ||
      attachment.file_type === ATTACHMENT_TYPES.AUDIO
  );

  return firstAudioAttachment?.id || null;
});

const audioPlaybackState = useAudioPlaybackState(firstAudioAttachmentId);
const audioTimeLabel = computed(() => audioPlaybackState.value.timeLabel);
const isIncomingOrientation = computed(() => orientation.value === 'left');
</script>

<template>
  <div class="message-meta-root text-xs flex items-center gap-1.5">
    <Label
      v-if="isCampaignMessage"
      :label="t('CAMPAIGN.BADGE.BROADCAST')"
      color="blue"
      compact
    />
    <Label
      v-if="isDelayedMessage"
      :label="t('CAMPAIGN.BADGE.DELAYED')"
      color="iris"
      compact
    />
    <span
      v-if="audioTimeLabel && !isIncomingOrientation"
      class="inline tabular-nums text-n-slate-11/90 font-medium whitespace-nowrap"
    >
      {{ audioTimeLabel }}
    </span>
    <div class="inline">
      <time class="inline">{{ readableTime }}</time>
    </div>
    <span v-if="subagentName" class="inline text-n-slate-11/90 font-medium">
      {{ subagentName }}
    </span>
    <span
      v-if="audioTimeLabel && isIncomingOrientation"
      class="inline tabular-nums text-n-slate-11/90 font-medium whitespace-nowrap"
    >
      {{ audioTimeLabel }}
    </span>
    <span v-if="isEdited" class="text-n-slate-11/80">
      {{ t('CONVERSATION.MESSAGE_EDITED') }}
    </span>
    <Icon v-if="isPrivate" icon="i-lucide-lock-keyhole" class="size-3" />
    <MessageStatus v-if="showStatusIndicator" :status="statusToShow" />
  </div>
</template>
