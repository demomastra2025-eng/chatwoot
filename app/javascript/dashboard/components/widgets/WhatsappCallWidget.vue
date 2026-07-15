<script setup>
import { computed, ref, watch, onUnmounted, onMounted } from 'vue';
import { useRouter } from 'vue-router';
import { useWhatsappCallSession } from 'dashboard/composables/useWhatsappCallSession';
import { useIncomingCallRingtone } from 'dashboard/composables/useIncomingCallRingtone';
import Avatar from 'dashboard/components-next/avatar/Avatar.vue';
import { useI18n } from 'vue-i18n';
import { emitter } from 'shared/helpers/mitt';
import { BUS_EVENTS } from 'shared/constants/busEvents';
import { useCallsStore } from 'dashboard/stores/calls';

const { t } = useI18n();
const router = useRouter();
const callsStore = useCallsStore();

const {
  activeCall,
  incomingCalls,
  hasActiveCall,
  isAccepting,
  isMuted,
  isOutboundRinging,
  isReconnecting,
  callError,
  formattedCallDuration,
  acceptCall,
  rejectCall,
  endActiveCall,
  toggleMute,
  dismissIncomingCall,
  startDurationTimer,
} = useWhatsappCallSession();

const hiddenCallIds = ref(new Set());
const callIdFor = call =>
  call?.callId || call?.id ? String(call.callId || call.id) : '';
const trackedCallIds = computed(() =>
  [callIdFor(activeCall.value), ...incomingCalls.value.map(callIdFor)].filter(
    Boolean
  )
);
const isCallHidden = call => {
  const callId = callIdFor(call);
  return callId && hiddenCallIds.value.has(callId);
};
const visibleIncomingCalls = computed(() =>
  incomingCalls.value.filter(call => !isCallHidden(call))
);
const showActiveCall = computed(
  () => hasActiveCall.value && !isCallHidden(activeCall.value)
);
const operatorBusy = computed(
  () => hasActiveCall.value || callsStore.hasActiveCall
);
const shouldPlayIncomingCallRingtone = computed(
  () =>
    !hasActiveCall.value &&
    !isAccepting.value &&
    visibleIncomingCalls.value.length > 0
);

useIncomingCallRingtone('whatsapp', shouldPlayIncomingCallRingtone);

// In server-relay mode, the timer starts when the Peer B WebRTC handshake
// completes (not when the agent clicks accept). Listen for this event.
const onAgentWebRTCConnected = () => {
  startDurationTimer();
};

const onPermissionGranted = ({ contactName }) => {
  emitter.emit(BUS_EVENTS.SHOW_ALERT, {
    message: t('WHATSAPP_CALL.PERMISSION_GRANTED', { contactName }),
    type: 'success',
  });
};

onMounted(() => {
  emitter.on('whatsapp_call:agent_webrtc_connected', onAgentWebRTCConnected);
  emitter.on('whatsapp_call:permission_granted', onPermissionGranted);
});

// Auto-dismiss ringing calls after 30 seconds
const autoRejectTimers = new Map();

const startAutoRejectTimer = call => {
  if (autoRejectTimers.has(call.callId)) return;
  const timer = setTimeout(() => {
    dismissIncomingCall(call);
    autoRejectTimers.delete(call.callId);
  }, 30000);
  autoRejectTimers.set(call.callId, timer);
};

const clearAutoRejectTimer = callId => {
  const timer = autoRejectTimers.get(callId);
  if (timer) {
    clearTimeout(timer);
    autoRejectTimers.delete(callId);
  }
};

const handleAccept = async call => {
  if (operatorBusy.value) {
    emitter.emit(BUS_EVENTS.SHOW_ALERT, {
      message: t('CONVERSATION.VOICE_WIDGET.OPERATOR_BUSY'),
      type: 'error',
    });
    return;
  }

  clearAutoRejectTimer(call.callId);
  await acceptCall(call);
  if (activeCall.value) {
    router.push({
      name: 'inbox_conversation',
      params: {
        conversation_id: call.conversationDisplayId || call.conversationId,
      },
    });
  }
};

const handleReject = async call => {
  clearAutoRejectTimer(call.callId);
  await rejectCall(call);
};

const handleEndCall = async () => {
  await endActiveCall();
};

const hideCall = call => {
  const callId = callIdFor(call);
  if (!callId) return;

  hiddenCallIds.value = new Set([...hiddenCallIds.value, callId]);
};

const handleCloseIncomingCall = call => {
  hideCall(call);
};

const handleCloseActiveCall = () => {
  hideCall(activeCall.value);
};

// Start auto-reject timers for each newly added incoming call
watch(
  incomingCalls,
  calls => {
    calls.forEach(call => startAutoRejectTimer(call));
  },
  { immediate: true, deep: true }
);

watch(trackedCallIds, callIds => {
  const activeCallIds = new Set(callIds);
  const nextHiddenCallIds = new Set(
    [...hiddenCallIds.value].filter(callId => activeCallIds.has(callId))
  );
  if (nextHiddenCallIds.size !== hiddenCallIds.value.size) {
    hiddenCallIds.value = nextHiddenCallIds;
  }
});

onUnmounted(() => {
  autoRejectTimers.forEach(timer => clearTimeout(timer));
  autoRejectTimers.clear();
  emitter.off('whatsapp_call:agent_webrtc_connected', onAgentWebRTCConnected);
  emitter.off('whatsapp_call:permission_granted', onPermissionGranted);
});
</script>

<template>
  <div
    v-show="callError || visibleIncomingCalls.length || showActiveCall"
    class="fixed ltr:right-4 rtl:left-4 bottom-20 z-50 flex flex-col gap-2 w-72"
  >
    <!-- Error banner -->
    <div
      v-if="callError"
      class="px-3 py-2 bg-n-ruby-3 border border-n-ruby-6 rounded-lg text-xs text-n-ruby-11"
    >
      {{ callError }}
    </div>

    <!-- Incoming calls remain visible while the operator is busy. -->
    <template v-if="visibleIncomingCalls.length">
      <div
        v-for="call in visibleIncomingCalls"
        :key="call.callId"
        class="relative flex items-center gap-3 p-4 ltr:pr-12 rtl:pl-12 bg-n-solid-2 rounded-xl shadow-xl outline outline-1 outline-n-strong"
      >
        <button
          type="button"
          class="absolute top-2 ltr:right-2 rtl:left-2 inline-flex size-7 p-0 justify-center items-center text-n-slate-10 hover:text-n-slate-12 hover:bg-n-alpha-2 rounded-md transition-colors"
          :title="t('WHATSAPP_CALL.CLOSE')"
          :aria-label="t('WHATSAPP_CALL.CLOSE')"
          @click="handleCloseIncomingCall(call)"
        >
          <i class="text-base i-lucide-x" />
        </button>
        <div
          class="animate-pulse ring-2 ring-n-teal-9 rounded-full inline-flex"
        >
          <Avatar
            :src="call.caller?.avatar"
            :name="call.caller?.name || call.caller?.phone"
            :size="40"
            rounded-full
          />
        </div>
        <div class="flex-1 min-w-0">
          <p class="text-sm font-medium text-n-slate-12 truncate mb-0">
            {{
              call.caller?.name ||
              call.caller?.phone ||
              t('WHATSAPP_CALL.UNKNOWN_CALLER')
            }}
          </p>
          <p class="text-xs text-n-slate-11 truncate">
            {{ t('WHATSAPP_CALL.INCOMING_WHATSAPP_CALL') }}
          </p>
        </div>
        <div class="flex shrink-0 gap-2">
          <button
            class="flex justify-center items-center w-10 h-10 bg-n-ruby-9 hover:bg-n-ruby-10 rounded-full transition-colors"
            :title="t('WHATSAPP_CALL.REJECT')"
            @click="handleReject(call)"
          >
            <i class="text-lg text-white i-ph-phone-x-bold" />
          </button>
          <button
            class="flex justify-center items-center w-10 h-10 bg-n-teal-9 hover:bg-n-teal-10 rounded-full transition-colors"
            :disabled="isAccepting || operatorBusy"
            :title="t('WHATSAPP_CALL.ACCEPT')"
            @click="handleAccept(call)"
          >
            <i
              v-if="isAccepting"
              class="text-lg text-white i-ph-circle-notch animate-spin"
            />
            <i v-else class="text-lg text-white i-ph-phone-bold" />
          </button>
        </div>
      </div>
    </template>

    <!-- Active call widget -->
    <div
      v-if="showActiveCall"
      class="relative flex items-center gap-3 p-4 ltr:pr-12 rtl:pl-12 bg-n-solid-2 rounded-xl shadow-xl outline outline-1 outline-n-strong"
    >
      <button
        type="button"
        class="absolute top-2 ltr:right-2 rtl:left-2 inline-flex size-7 p-0 justify-center items-center text-n-slate-10 hover:text-n-slate-12 hover:bg-n-alpha-2 rounded-md transition-colors"
        :title="t('WHATSAPP_CALL.CLOSE')"
        :aria-label="t('WHATSAPP_CALL.CLOSE')"
        @click="handleCloseActiveCall"
      >
        <i class="text-base i-lucide-x" />
      </button>
      <div
        class="ring-2 ring-n-teal-9 rounded-full inline-flex"
        :class="{ 'animate-pulse': isOutboundRinging }"
      >
        <Avatar
          :src="activeCall.caller?.avatar"
          :name="activeCall.caller?.name || activeCall.caller?.phone"
          :size="40"
          rounded-full
        />
      </div>
      <div class="flex-1 min-w-0">
        <p class="text-sm font-medium text-n-slate-12 truncate mb-0">
          {{
            activeCall.caller?.name ||
            activeCall.caller?.phone ||
            t('WHATSAPP_CALL.UNKNOWN_CALLER')
          }}
        </p>
        <p
          class="text-sm"
          :class="
            isOutboundRinging || isReconnecting
              ? 'text-n-slate-11'
              : 'font-mono text-n-teal-9'
          "
        >
          <template v-if="isReconnecting">
            {{ t('WHATSAPP_CALL.RECONNECTING') }}
          </template>
          <template v-else-if="isOutboundRinging">
            {{ t('WHATSAPP_CALL.RINGING') }}
          </template>
          <template v-else>
            {{ formattedCallDuration }}
          </template>
        </p>
      </div>
      <div class="flex shrink-0 gap-2">
        <!-- Mute toggle -->
        <button
          class="flex justify-center items-center w-9 h-9 rounded-full transition-colors"
          :class="
            isMuted
              ? 'bg-n-amber-9 hover:bg-n-amber-10'
              : 'bg-n-slate-4 hover:bg-n-slate-5'
          "
          :title="isMuted ? t('WHATSAPP_CALL.UNMUTE') : t('WHATSAPP_CALL.MUTE')"
          @click="toggleMute"
        >
          <i
            class="text-base text-white"
            :class="
              isMuted ? 'i-ph-microphone-slash-bold' : 'i-ph-microphone-bold'
            "
          />
        </button>
        <!-- Hang up -->
        <button
          class="flex justify-center items-center w-9 h-9 bg-n-ruby-9 hover:bg-n-ruby-10 rounded-full transition-colors"
          :title="t('WHATSAPP_CALL.HANG_UP')"
          @click="handleEndCall"
        >
          <i class="text-base text-white i-ph-phone-x-bold" />
        </button>
      </div>
    </div>
  </div>
</template>
