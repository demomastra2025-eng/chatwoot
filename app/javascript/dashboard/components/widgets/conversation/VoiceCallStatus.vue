<script setup>
import { computed } from 'vue';
import { useI18n } from 'vue-i18n';
import {
  VOICE_CALL_STATUS,
  VOICE_CALL_DIRECTION,
} from 'dashboard/components-next/message/constants';
import Icon from 'dashboard/components-next/icon/Icon.vue';

const props = defineProps({
  status: { type: String, default: '' },
  direction: { type: String, default: '' },
  messagePreviewClass: { type: [String, Array, Object], default: '' },
});

const { t } = useI18n();

const RINGING_STATUSES = ['created', 'queued', 'initiated', 'routing'];
const FAILED_STATUSES = [
  VOICE_CALL_STATUS.MISSED,
  VOICE_CALL_STATUS.NO_ANSWER,
  VOICE_CALL_STATUS.FAILED,
  VOICE_CALL_STATUS.BUSY,
  VOICE_CALL_STATUS.REJECTED,
  VOICE_CALL_STATUS.CANCELLED,
];

const ICON_MAP = {
  [VOICE_CALL_STATUS.IN_PROGRESS]: 'i-ph-phone-call',
  [VOICE_CALL_STATUS.MISSED]: 'i-ph-phone-x',
  [VOICE_CALL_STATUS.NO_ANSWER]: 'i-ph-phone-x',
  [VOICE_CALL_STATUS.FAILED]: 'i-ph-phone-x',
  [VOICE_CALL_STATUS.BUSY]: 'i-ph-phone-x',
  [VOICE_CALL_STATUS.REJECTED]: 'i-ph-phone-x',
  [VOICE_CALL_STATUS.CANCELLED]: 'i-ph-phone-x',
};

const COLOR_MAP = {
  [VOICE_CALL_STATUS.IN_PROGRESS]: 'text-n-teal-9',
  [VOICE_CALL_STATUS.RINGING]: 'text-n-teal-9',
  [VOICE_CALL_STATUS.COMPLETED]: 'text-n-slate-11',
  [VOICE_CALL_STATUS.MISSED]: 'text-n-ruby-9',
  [VOICE_CALL_STATUS.NO_ANSWER]: 'text-n-ruby-9',
  [VOICE_CALL_STATUS.FAILED]: 'text-n-ruby-9',
  [VOICE_CALL_STATUS.BUSY]: 'text-n-ruby-9',
  [VOICE_CALL_STATUS.REJECTED]: 'text-n-ruby-9',
  [VOICE_CALL_STATUS.CANCELLED]: 'text-n-ruby-9',
};

const normalizeVoiceCallStatus = value => {
  const rawStatus = value?.toString()?.trim()?.toLowerCase();
  if (RINGING_STATUSES.includes(rawStatus)) {
    return VOICE_CALL_STATUS.RINGING;
  }
  if (rawStatus === 'in_progress') return VOICE_CALL_STATUS.IN_PROGRESS;
  if (rawStatus === 'no_answer') return VOICE_CALL_STATUS.NO_ANSWER;
  return rawStatus;
};

const normalizeVoiceCallDirection = value => {
  const rawDirection = value?.toString()?.trim()?.toLowerCase();
  if (rawDirection === VOICE_CALL_DIRECTION.OUTBOUND) {
    return VOICE_CALL_DIRECTION.OUTBOUND;
  }
  if (rawDirection === VOICE_CALL_DIRECTION.INBOUND) {
    return VOICE_CALL_DIRECTION.INBOUND;
  }
  return '';
};

const normalizedStatus = computed(() => normalizeVoiceCallStatus(props.status));
const normalizedDirection = computed(() =>
  normalizeVoiceCallDirection(props.direction)
);
const isOutbound = computed(
  () => normalizedDirection.value === VOICE_CALL_DIRECTION.OUTBOUND
);
const isFailed = computed(() =>
  FAILED_STATUSES.includes(normalizedStatus.value)
);

const labelText = computed(() => {
  if (normalizedStatus.value === VOICE_CALL_STATUS.IN_PROGRESS) {
    return t('CONVERSATION.VOICE_CALL.CALL_IN_PROGRESS');
  }
  if (normalizedStatus.value === VOICE_CALL_STATUS.COMPLETED) {
    return t('CONVERSATION.VOICE_CALL.CALL_ENDED');
  }
  if (normalizedStatus.value === VOICE_CALL_STATUS.RINGING) {
    return isOutbound.value
      ? t('CONVERSATION.VOICE_CALL.OUTGOING_CALL')
      : t('CONVERSATION.VOICE_CALL.INCOMING_CALL');
  }
  if (isFailed.value) {
    return isOutbound.value
      ? t('CONVERSATION.VOICE_CALL.OUTGOING_CALL')
      : t('CONVERSATION.VOICE_CALL.MISSED_CALL');
  }
  return isOutbound.value
    ? t('CONVERSATION.VOICE_CALL.OUTGOING_CALL')
    : t('CONVERSATION.VOICE_CALL.INCOMING_CALL');
});

const iconName = computed(() => {
  if (ICON_MAP[normalizedStatus.value]) return ICON_MAP[normalizedStatus.value];
  return isOutbound.value ? 'i-ph-phone-outgoing' : 'i-ph-phone-incoming';
});

const statusColor = computed(
  () => COLOR_MAP[normalizedStatus.value] || 'text-n-slate-11'
);
</script>

<template>
  <div
    class="my-0 mx-2 leading-6 h-6 flex-1 min-w-0 text-sm overflow-hidden text-ellipsis whitespace-nowrap"
    :class="messagePreviewClass"
  >
    <Icon
      class="inline-block -mt-0.5 align-middle size-4"
      :icon="iconName"
      :class="statusColor"
    />
    <span class="mx-1" :class="statusColor">
      {{ labelText }}
    </span>
  </div>
</template>
