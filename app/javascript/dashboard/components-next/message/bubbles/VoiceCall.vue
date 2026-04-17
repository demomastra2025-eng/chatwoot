<script setup>
import { computed } from 'vue';
import { useMessageContext } from '../provider.js';
import { MESSAGE_TYPES, VOICE_CALL_STATUS } from '../constants';
import { messageTimestamp } from 'shared/helpers/timeHelper';

import Icon from 'dashboard/components-next/icon/Icon.vue';
import BaseBubble from 'next/message/bubbles/Base.vue';

const LABEL_MAP = {
  [VOICE_CALL_STATUS.IN_PROGRESS]: 'CONVERSATION.VOICE_CALL.CALL_IN_PROGRESS',
  [VOICE_CALL_STATUS.COMPLETED]: 'CONVERSATION.VOICE_CALL.CALL_ENDED',
};

const SUBTEXT_MAP = {
  [VOICE_CALL_STATUS.RINGING]: 'CONVERSATION.VOICE_CALL.NOT_ANSWERED_YET',
  [VOICE_CALL_STATUS.COMPLETED]: 'CONVERSATION.VOICE_CALL.CALL_ENDED',
};

const ICON_MAP = {
  [VOICE_CALL_STATUS.IN_PROGRESS]: 'i-ph-phone-call',
  [VOICE_CALL_STATUS.NO_ANSWER]: 'i-ph-phone-x',
  [VOICE_CALL_STATUS.FAILED]: 'i-ph-phone-x',
};

const BG_COLOR_MAP = {
  [VOICE_CALL_STATUS.IN_PROGRESS]: 'bg-n-teal-9',
  [VOICE_CALL_STATUS.RINGING]: 'bg-n-teal-9 animate-pulse',
  [VOICE_CALL_STATUS.COMPLETED]: 'bg-n-slate-11',
  [VOICE_CALL_STATUS.NO_ANSWER]: 'bg-n-ruby-9',
  [VOICE_CALL_STATUS.FAILED]: 'bg-n-ruby-9',
};

const { contentAttributes, messageType, createdAt } = useMessageContext();

const data = computed(() => contentAttributes.value?.data);
const status = computed(() => data.value?.status?.toString());
const meta = computed(() => data.value?.meta || {});

const isOutbound = computed(() => messageType.value === MESSAGE_TYPES.OUTGOING);
const isFailed = computed(() =>
  [VOICE_CALL_STATUS.NO_ANSWER, VOICE_CALL_STATUS.FAILED].includes(status.value)
);
const timeLabel = computed(() => messageTimestamp(createdAt.value, 'HH:mm'));

const durationInSeconds = computed(() => {
  const explicitDuration = Number(meta.value?.duration);
  if (Number.isFinite(explicitDuration) && explicitDuration >= 0) {
    return explicitDuration;
  }

  const startedAt = Number(meta.value?.started_at);
  const endedAt = Number(meta.value?.ended_at);
  if (
    Number.isFinite(startedAt) &&
    Number.isFinite(endedAt) &&
    endedAt >= startedAt
  ) {
    return endedAt - startedAt;
  }

  return null;
});

const durationLabel = computed(() => {
  const totalSeconds = durationInSeconds.value;
  if (!Number.isFinite(totalSeconds)) {
    return '';
  }

  const hours = Math.floor(totalSeconds / 3600);
  const minutes = Math.floor((totalSeconds % 3600) / 60);
  const seconds = totalSeconds % 60;

  if (hours > 0) {
    return [hours, minutes, seconds]
      .map(unit => String(unit).padStart(2, '0'))
      .join(':');
  }

  return [minutes, seconds]
    .map(unit => String(unit).padStart(2, '0'))
    .join(':');
});

const labelKey = computed(() => {
  if (LABEL_MAP[status.value]) return LABEL_MAP[status.value];
  if (status.value === VOICE_CALL_STATUS.RINGING) {
    return isOutbound.value
      ? 'CONVERSATION.VOICE_CALL.OUTGOING_CALL'
      : 'CONVERSATION.VOICE_CALL.INCOMING_CALL';
  }
  return isFailed.value
    ? 'CONVERSATION.VOICE_CALL.MISSED_CALL'
    : 'CONVERSATION.VOICE_CALL.INCOMING_CALL';
});

const subtextKey = computed(() => {
  if (SUBTEXT_MAP[status.value]) return SUBTEXT_MAP[status.value];
  if (status.value === VOICE_CALL_STATUS.IN_PROGRESS) {
    return isOutbound.value
      ? 'CONVERSATION.VOICE_CALL.THEY_ANSWERED'
      : 'CONVERSATION.VOICE_CALL.YOU_ANSWERED';
  }
  return isFailed.value
    ? 'CONVERSATION.VOICE_CALL.NO_ANSWER'
    : 'CONVERSATION.VOICE_CALL.NOT_ANSWERED_YET';
});

const iconName = computed(() => {
  if (ICON_MAP[status.value]) return ICON_MAP[status.value];
  return isOutbound.value ? 'i-ph-phone-outgoing' : 'i-ph-phone-incoming';
});

const bgColor = computed(() => BG_COLOR_MAP[status.value] || 'bg-n-teal-9');
</script>

<template>
  <BaseBubble class="p-0 border-none" hide-meta>
    <div class="flex overflow-hidden flex-col w-full max-w-xs">
      <div class="flex gap-3 items-center p-3 w-full">
        <div
          class="flex justify-center items-center rounded-full size-10 shrink-0"
          :class="bgColor"
        >
          <Icon
            class="size-5"
            :icon="iconName"
            :class="{
              'text-n-slate-1': status === VOICE_CALL_STATUS.COMPLETED,
              'text-white': status !== VOICE_CALL_STATUS.COMPLETED,
            }"
          />
        </div>

        <div class="flex overflow-hidden flex-col flex-grow">
          <span class="text-sm font-medium truncate text-n-slate-12">
            {{ $t(labelKey) }}
          </span>
          <span class="text-xs text-n-slate-11">
            {{ $t(subtextKey) }}
          </span>
          <div
            v-if="timeLabel || durationLabel"
            class="flex gap-1 items-center mt-1 text-xs tabular-nums text-n-slate-11/90"
          >
            <time v-if="timeLabel">{{ timeLabel }}</time>
            <span v-if="timeLabel && durationLabel">&bull;</span>
            <span v-if="durationLabel">{{ durationLabel }}</span>
          </div>
        </div>
      </div>
    </div>
  </BaseBubble>
</template>
