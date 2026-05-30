<script setup>
import { computed } from 'vue';
import { emitter } from 'shared/helpers/mitt';
import { useTrack } from 'dashboard/composables';

import { BUS_EVENTS } from 'shared/constants/busEvents';
import { INBOX_TYPES } from 'dashboard/helper/inbox';
import { COPILOT_EVENTS } from 'dashboard/helper/AnalyticsHelper/events';
import MessageFormatter from 'shared/helpers/MessageFormatter.js';
import { normalizeCaptainUiActions } from 'dashboard/helper/captainUiActions';

import Button from 'dashboard/components-next/button/Button.vue';
import CaptainToolExecutionGroup from 'dashboard/components-next/message/CaptainToolExecutionGroup.vue';

const props = defineProps({
  isLastMessage: {
    type: Boolean,
    default: false,
  },
  message: {
    type: Object,
    required: true,
  },
  conversationInboxType: {
    type: String,
    required: true,
  },
});

const emit = defineEmits(['uiAction']);
const hasEmptyMessageContent = computed(() => !props.message?.content);

const showUseButton = computed(() => {
  return (
    !hasEmptyMessageContent.value &&
    props.message.reply_suggestion &&
    props.isLastMessage
  );
});

const messageContent = computed(() => {
  const formatter = new MessageFormatter(props.message.content);
  return formatter.formattedMessage;
});

const uiActions = computed(() =>
  normalizeCaptainUiActions(
    props.message?.ui_actions || props.message?.uiActions
  )
);

const captainTraceAttributes = computed(() => {
  const additionalAttributes =
    props.message?.additional_attributes ||
    props.message?.additionalAttributes ||
    {};
  const captainTrace =
    props.message?.captain_trace ||
    props.message?.captainTrace ||
    additionalAttributes.captain_trace ||
    additionalAttributes.captainTrace;

  return {
    ...additionalAttributes,
    captain_trace: captainTrace,
  };
});

const handleUiAction = action => {
  emit('uiAction', action);
};

const insertIntoRichEditor = computed(() => {
  return [INBOX_TYPES.WEB, INBOX_TYPES.EMAIL].includes(
    props.conversationInboxType
  );
});

const useCopilotResponse = () => {
  if (insertIntoRichEditor.value) {
    emitter.emit(BUS_EVENTS.INSERT_INTO_RICH_EDITOR, props.message?.content);
  } else {
    emitter.emit(BUS_EVENTS.INSERT_INTO_NORMAL_EDITOR, props.message?.content);
  }
  useTrack(COPILOT_EVENTS.USE_CAPTAIN_RESPONSE);
};
</script>

<template>
  <div class="flex flex-col gap-1 text-n-slate-12">
    <div class="font-medium">{{ $t('CAPTAIN.NAME') }}</div>
    <span v-if="hasEmptyMessageContent" class="text-n-ruby-11">
      {{ $t('CAPTAIN.COPILOT.EMPTY_MESSAGE') }}
    </span>
    <div
      v-else
      v-dompurify-html="messageContent"
      class="prose-sm break-words"
    />
    <CaptainToolExecutionGroup
      :additional-attributes="captainTraceAttributes"
    />
    <div class="flex flex-row mt-1 gap-2 flex-wrap">
      <Button
        v-if="showUseButton"
        :label="$t('CAPTAIN.COPILOT.USE')"
        faded
        sm
        slate
        @click="useCopilotResponse"
      />
      <Button
        v-for="action in uiActions"
        :key="`${action.type}-${action.targetId}`"
        :label="action.label"
        faded
        sm
        slate
        @click="handleUiAction(action)"
      />
    </div>
  </div>
</template>
