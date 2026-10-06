<script setup>
import { computed, onBeforeUnmount, onMounted, ref, watch } from 'vue';
import { useI18n } from 'vue-i18n';
import { useMapGetter } from 'dashboard/composables/store';
import { useEmitter } from 'dashboard/composables/emitter';
import { BUS_EVENTS } from 'shared/constants/busEvents';
import VoiceAPI from 'dashboard/api/channel/voice/voiceAPIClient';
import {
  OPERATOR_ACTIVITY_STATES,
  useCallOperatorActivityStore,
} from 'dashboard/stores/callOperatorActivity';

// "Operator X is calling the client" / "... is talking to the client": a quiet
// line for the other operators who have this chat open. The realtime events
// keep it current; the server is asked when the chat opens and when the
// connection comes back, so a reloaded page shows the call that is on.
const props = defineProps({
  chat: { type: Object, default: () => ({}) },
});

const { t } = useI18n();
const activityStore = useCallOperatorActivityStore();
const currentUserId = useMapGetter('getCurrentUserID');
const inboxGetter = useMapGetter('inboxes/getInbox');

const PRUNE_INTERVAL_MS = 15000;
const now = ref(Date.now());
let pruneTimerId = null;

const hasVoiceChannel = computed(() => {
  const { chat } = props;
  if (!chat?.id) return false;
  if (chat.is_communication_thread) {
    return (chat.channels || []).some(
      channel => channel?.channel === 'Channel::Voice'
    );
  }
  return inboxGetter.value(chat.inbox_id)?.channel_type === 'Channel::Voice';
});

const lines = computed(() =>
  activityStore.forChat(props.chat, currentUserId.value, now.value)
);

const lineText = line =>
  t(
    line.state === OPERATOR_ACTIVITY_STATES.TALKING
      ? 'CONVERSATION.OPERATOR_CALL_ACTIVITY.TALKING'
      : 'CONVERSATION.OPERATOR_CALL_ACTIVITY.CALLING',
    { name: line.operatorName }
  );

const fetchActivity = async () => {
  const chat = props.chat;
  if (!hasVoiceChannel.value) return;

  // The answer describes the moment of the request: realtime events that
  // arrive after this are newer than it and win over it.
  const requestedAt = Date.now();
  try {
    const items = await VoiceAPI.getOperatorActivity(
      chat.is_communication_thread
        ? { communicationThreadId: chat.id }
        : { conversationId: chat.id }
    );
    // The employee may have moved to another chat while the answer came.
    if (props.chat?.id !== chat.id) return;
    activityStore.syncChat(chat, items, currentUserId.value, Date.now(), {
      requestedAt,
    });
  } catch {
    // The realtime events keep the line current; nothing to tell the user.
  }
};

// The inbox list can arrive after the chat on a hard reload, so the check also
// runs again when the chat turns out to be a voice one.
watch([() => props.chat?.id, hasVoiceChannel], fetchActivity, {
  immediate: true,
});
useEmitter(BUS_EVENTS.WEBSOCKET_RECONNECT_COMPLETED, fetchActivity);

onMounted(() => {
  pruneTimerId = setInterval(() => {
    now.value = Date.now();
    activityStore.pruneStale(now.value);
  }, PRUNE_INTERVAL_MS);
});

onBeforeUnmount(() => {
  clearInterval(pruneTimerId);
});
</script>

<template>
  <div
    v-if="lines.length"
    class="flex flex-col gap-1 px-4 py-2 border-t border-n-weak"
    data-testid="call-operator-activity"
    role="status"
    aria-live="polite"
  >
    <p
      v-for="line in lines"
      :key="line.callId"
      class="flex items-center gap-2 mb-0 text-xs text-n-slate-11"
      :data-state="line.state"
    >
      <span
        class="size-1.5 rounded-full shrink-0"
        :class="
          line.state === OPERATOR_ACTIVITY_STATES.TALKING
            ? 'bg-n-teal-9'
            : 'bg-n-slate-9 animate-pulse'
        "
        aria-hidden="true"
      />
      <span class="truncate">{{ lineText(line) }}</span>
    </p>
  </div>
</template>
