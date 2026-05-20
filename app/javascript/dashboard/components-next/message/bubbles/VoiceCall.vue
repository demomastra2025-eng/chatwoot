<script setup>
import { computed, ref } from 'vue';
import { useRouter } from 'vue-router';
import { useMessageContext } from '../provider.js';
import { MESSAGE_TYPES, VOICE_CALL_STATUS } from '../constants';
import { acceptWhatsappCallById } from 'dashboard/composables/useWhatsappCallSession';
import { messageTimestamp } from 'shared/helpers/timeHelper';

import Icon from 'dashboard/components-next/icon/Icon.vue';
import BaseBubble from 'next/message/bubbles/Base.vue';
import AudioChip from 'next/message/chips/Audio.vue';

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

const TERMINAL_RECORDING_STATUSES = [
  VOICE_CALL_STATUS.COMPLETED,
  VOICE_CALL_STATUS.NO_ANSWER,
  VOICE_CALL_STATUS.FAILED,
  'cancelled',
];

const router = useRouter();
const { contentAttributes, messageType, createdAt } = useMessageContext();

// NOTE: contentAttributes.data keys are camelCase because MessageList.vue
// applies useCamelCase(messages, { deep: true }) before rendering.
const normalizeVoiceCallStatus = value => {
  const rawStatus = value?.toString();
  if (rawStatus === 'in_progress') return VOICE_CALL_STATUS.IN_PROGRESS;
  if (rawStatus === 'no_answer') return VOICE_CALL_STATUS.NO_ANSWER;
  return rawStatus;
};

const data = computed(() => contentAttributes.value?.data);
const status = computed(() => normalizeVoiceCallStatus(data.value?.status));
const meta = computed(() => data.value?.meta || {});

const isOutbound = computed(() => messageType.value === MESSAGE_TYPES.OUTGOING);
const isFailed = computed(() =>
  [VOICE_CALL_STATUS.NO_ANSWER, VOICE_CALL_STATUS.FAILED].includes(status.value)
);

// Call source and metadata — all camelCase due to deep transform
const isWhatsappCall = computed(() => data.value?.callSource === 'whatsapp');
const callId = computed(() => data.value?.callId);
const acceptedBy = computed(() => data.value?.acceptedBy);
const recordingUrl = computed(
  () =>
    data.value?.recordingUrl ||
    data.value?.recording_url ||
    data.value?.recording?.recordingUrl ||
    data.value?.recording?.recording_url
);
const transcript = computed(() => data.value?.transcript);
const transcriptItems = computed(() => data.value?.transcriptItems || []);
const aiVoice = computed(() => data.value?.aiVoice || {});
const tools = computed(() => data.value?.tools || []);
const isAiVoice = computed(() => Boolean(aiVoice.value?.enabled));
const aiVoiceState = computed(() => aiVoice.value?.state?.toString());
const timelineMessagesEnabled = computed(
  () => isAiVoice.value && Boolean(aiVoice.value?.timelineMessagesEnabled)
);
const showTools = computed(
  () => !timelineMessagesEnabled.value && tools.value.length > 0
);
const isJoining = ref(false);
const timeLabel = computed(() => messageTimestamp(createdAt.value, 'HH:mm'));
const hasRenderableRecordingStatus = computed(() =>
  TERMINAL_RECORDING_STATUSES.includes(status.value)
);

const durationInSeconds = computed(() => {
  const explicitDuration = Number(
    data.value?.durationSeconds ?? data.value?.duration ?? meta.value?.duration
  );
  if (Number.isFinite(explicitDuration) && explicitDuration >= 0) {
    return explicitDuration;
  }

  const startedAt = Number(meta.value?.startedAt ?? meta.value?.started_at);
  const endedAt = Number(meta.value?.endedAt ?? meta.value?.ended_at);
  if (
    Number.isFinite(startedAt) &&
    Number.isFinite(endedAt) &&
    endedAt >= startedAt
  ) {
    return endedAt - startedAt;
  }

  return null;
});

const formattedDuration = computed(() => {
  const seconds = durationInSeconds.value;
  if (!Number.isFinite(seconds)) return '';
  if (seconds <= 0) return '00:00';
  const mins = Math.floor(seconds / 60);
  const secs = seconds % 60;
  return [mins, secs].map(unit => String(unit).padStart(2, '0')).join(':');
});

const voiceCallBubbleStyle = computed(() => {
  if (!(recordingUrl.value && hasRenderableRecordingStatus.value)) {
    return {
      '--voice-call-bubble-width': '20rem',
    };
  }

  const seconds = durationInSeconds.value;
  const widthRem = Number.isFinite(seconds)
    ? Math.min(48, Math.max(24, 24 + seconds / 8))
    : 24;

  return {
    '--voice-call-bubble-width': `min(${widthRem}rem, calc(100vw - 8rem))`,
  };
});

const recordingExtension = computed(() => {
  const contentType = data.value?.recording?.contentType;
  if (contentType === 'audio/mpeg') return 'mp3';
  if (contentType?.startsWith('audio/')) {
    return contentType.split('/').pop()?.replace(/^x-/, '') || 'wav';
  }

  const path = recordingUrl.value?.split('?')[0] || '';
  const extension = path.split('.').pop();
  return extension && extension !== path ? extension.toLowerCase() : 'wav';
});

const transcriptFallback = computed(() => {
  if (transcript.value) return transcript.value;
  return transcriptItems.value
    .map(item => `${item.speaker === 'ai' ? 'ИИ' : 'Клиент'}: ${item.text}`)
    .join('\n');
});

const recordingTranscribedText = computed(() => {
  if (timelineMessagesEnabled.value) return '';
  return transcriptFallback.value;
});

const recordingAttachment = computed(() => {
  if (!recordingUrl.value) return null;

  const recordingRef =
    data.value?.recordingRef || data.value?.recording?.recordingRef;
  const callRef = callId.value || data.value?.callSid || recordingRef;

  return {
    id: recordingRef || callRef || recordingUrl.value,
    fileType: 'audio',
    extension: recordingExtension.value,
    dataUrl: recordingUrl.value,
    transcribedText: recordingTranscribedText.value,
  };
});

// Show join/accept button logic.
// WhatsApp with media server: ringing + in_progress (server-relay supports rejoin).
// WhatsApp without media server: only ringing (peer-to-peer WebRTC — cannot rejoin after accept).
const showJoinButton = computed(() => {
  if (!isWhatsappCall.value) return false;

  // Server-relay mode enables rejoining in-progress calls.
  const isMediaServerMode = data.value?.mediaServerEnabled;
  if (isMediaServerMode) {
    return [VOICE_CALL_STATUS.RINGING, VOICE_CALL_STATUS.IN_PROGRESS].includes(
      status.value
    );
  }
  return status.value === VOICE_CALL_STATUS.RINGING;
});

const joinButtonLabel = computed(() => {
  if (isWhatsappCall.value && status.value === VOICE_CALL_STATUS.RINGING) {
    return 'CONVERSATION.VOICE_CALL.ACCEPT_CALL';
  }
  return 'CONVERSATION.VOICE_CALL.JOIN_CALL';
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
  if (isAiVoice.value) {
    if (aiVoiceState.value === 'speaking') {
      return 'CONVERSATION.VOICE_CALL.AI_AGENT_SPEAKING';
    }
    if (aiVoiceState.value === 'using_tool') {
      return 'CONVERSATION.VOICE_CALL.AI_AGENT_USING_TOOL';
    }
    if (aiVoice.value?.answered) {
      return 'CONVERSATION.VOICE_CALL.AI_AGENT_ANSWERED';
    }
  }

  if (
    acceptedBy.value?.name &&
    [VOICE_CALL_STATUS.IN_PROGRESS, VOICE_CALL_STATUS.COMPLETED].includes(
      status.value
    )
  ) {
    return null;
  }

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

const answeredByText = computed(() => {
  if (!acceptedBy.value?.name) return '';
  return acceptedBy.value.name;
});

const iconName = computed(() => {
  if (ICON_MAP[status.value]) return ICON_MAP[status.value];
  return isOutbound.value ? 'i-ph-phone-outgoing' : 'i-ph-phone-incoming';
});

const bgColor = computed(() => BG_COLOR_MAP[status.value] || 'bg-n-teal-9');

const toolStatusClass = tool => {
  if (tool.status === 'failed') return 'text-n-ruby-11';
  if (tool.status === 'completed') return 'text-n-teal-11';
  return 'text-n-amber-11';
};

const toolStatusKey = tool => {
  if (tool.status === 'failed') return 'CONVERSATION.VOICE_CALL.TOOL_FAILED';
  if (tool.status === 'completed') {
    return 'CONVERSATION.VOICE_CALL.TOOL_COMPLETED';
  }
  return 'CONVERSATION.VOICE_CALL.TOOL_RUNNING';
};

const handleJoinCall = async () => {
  if (isJoining.value) return;
  isJoining.value = true;

  try {
    if (isWhatsappCall.value) {
      const result = await acceptWhatsappCallById(callId.value);
      if (result?.success && result.call) {
        router.push({
          name: 'inbox_conversation',
          params: {
            conversation_id:
              result.call.conversationDisplayId || result.call.conversationId,
          },
        });
      }
    }
  } catch (err) {
    // eslint-disable-next-line no-console
    console.error('[WhatsApp Call] Accept from bubble failed:', err);
  } finally {
    isJoining.value = false;
  }
};
</script>

<template>
  <BaseBubble
    class="p-0 overflow-hidden border-none !max-w-[min(48rem,calc(100vw-8rem))]"
    hide-meta
  >
    <div
      class="voice-call-bubble-body flex overflow-hidden flex-col w-[var(--voice-call-bubble-width)] max-w-full"
      :style="voiceCallBubbleStyle"
    >
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

        <div class="flex overflow-hidden flex-col flex-grow gap-0.5">
          <span class="text-sm font-medium truncate text-n-slate-12">
            {{ $t(labelKey) }}
          </span>
          <span v-if="answeredByText" class="text-xs text-n-slate-11">
            {{
              $t('CONVERSATION.VOICE_CALL.ANSWERED_BY', {
                name: answeredByText,
              })
            }}
          </span>
          <span
            v-else-if="subtextKey && !isAiVoice"
            class="text-xs text-n-slate-11"
          >
            {{ $t(subtextKey) }}
          </span>
          <div
            v-if="isAiVoice"
            class="flex gap-1 items-center mt-1 text-xs font-medium text-n-teal-11"
          >
            <i class="i-woot-captain text-sm" />
            <span>{{ $t(subtextKey) }}</span>
          </div>
          <div
            v-if="timeLabel || formattedDuration"
            class="flex gap-1 items-center mt-1 text-xs tabular-nums text-n-slate-11/90"
          >
            <time v-if="timeLabel">{{ timeLabel }}</time>
            <span v-if="timeLabel && formattedDuration">&bull;</span>
            <span v-if="formattedDuration">{{ formattedDuration }}</span>
          </div>
        </div>

        <button
          v-if="showJoinButton"
          :disabled="isJoining"
          class="flex items-center gap-1 px-3 py-1.5 text-xs font-medium text-white bg-n-teal-9 hover:bg-n-teal-10 rounded-lg transition-colors shrink-0"
          :class="{ 'opacity-75 cursor-wait': isJoining }"
          @click="handleJoinCall"
        >
          <i
            v-if="isJoining"
            class="i-ph-circle-notch-bold text-sm animate-spin"
          />
          <i v-else class="i-ph-phone-bold text-sm" />
          {{ $t(joinButtonLabel) }}
        </button>
      </div>

      <div
        v-if="recordingAttachment && hasRenderableRecordingStatus"
        class="px-3 pb-2"
      >
        <AudioChip
          :attachment="recordingAttachment"
          show-transcribed-text
          class="!w-full rounded-xl bg-n-alpha-1 px-2 py-2 text-n-slate-12 skip-context-menu"
        />
      </div>

      <div v-if="showTools" class="px-3 pb-3">
        <div class="mb-1 text-xs font-medium text-n-slate-11">
          {{ $t('CONVERSATION.VOICE_CALL.TOOLS_USED') }}
        </div>
        <div class="flex flex-col gap-1">
          <div
            v-for="(tool, index) in tools"
            :key="`${tool.name}-${tool.event}-${tool.at}-${index}`"
            class="flex items-center justify-between gap-2 rounded-md bg-n-alpha-2 px-2 py-1 text-xs"
          >
            <span class="font-mono text-n-slate-12 truncate">
              {{ tool.name }}
            </span>
            <span class="shrink-0" :class="toolStatusClass(tool)">
              {{ $t(toolStatusKey(tool)) }}
            </span>
          </div>
        </div>
      </div>
    </div>
  </BaseBubble>
</template>
