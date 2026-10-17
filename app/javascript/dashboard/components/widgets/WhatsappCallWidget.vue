<script setup>
import { computed, ref, watch, onUnmounted, onMounted } from 'vue';
import { useRouter } from 'vue-router';
import { useWhatsappCallSession } from 'dashboard/composables/useWhatsappCallSession';
import { useIncomingCallAttention } from 'dashboard/composables/useIncomingCallAttention';
import { useIncomingCallRingtone } from 'dashboard/composables/useIncomingCallRingtone';
import Avatar from 'dashboard/components-next/avatar/Avatar.vue';
import { useI18n } from 'vue-i18n';
import { emitter } from 'shared/helpers/mitt';
import { BUS_EVENTS } from 'shared/constants/busEvents';
import { useCallsStore } from 'dashboard/stores/calls';

const props = defineProps({
  embedded: { type: Boolean, default: false },
  silent: { type: Boolean, default: false },
});

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

const CALL_CARD_EXPANDED_STORAGE_KEY = 'chatwoot_call_card_expanded';
const readInitialCallCardExpanded = () => {
  try {
    const raw = window.localStorage?.getItem(CALL_CARD_EXPANDED_STORAGE_KEY);
    if (raw === 'false') return false;
    if (raw === 'true') return true;
  } catch {
    // Ignore storage read errors
  }
  return true;
};
const isCallCardExpanded = ref(readInitialCallCardExpanded());
const toggleCallCardExpanded = () => {
  const nextValue = !isCallCardExpanded.value;
  isCallCardExpanded.value = nextValue;
  try {
    window.localStorage?.setItem(
      CALL_CARD_EXPANDED_STORAGE_KEY,
      String(nextValue)
    );
  } catch {
    // Ignore storage write errors
  }
};

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
    !props.silent &&
    !operatorBusy.value &&
    !isAccepting.value &&
    visibleIncomingCalls.value.length > 0
);

useIncomingCallRingtone('whatsapp', shouldPlayIncomingCallRingtone);
useIncomingCallAttention(
  'whatsapp',
  computed(() =>
    shouldPlayIncomingCallRingtone.value
      ? visibleIncomingCalls.value.map(call => ({
          key: callIdFor(call),
          body: `${call.caller?.name || call.caller?.phone || t('CONVERSATION.VOICE_WIDGET.UNKNOWN_CALLER')} · WhatsApp`,
        }))
      : []
  )
);

// Same words as the phone widget microphone (translated in ru/en/kk).
const microphoneLabel = computed(() =>
  isMuted.value
    ? t('PHONE_WIDGET.MICROPHONE_MUTED')
    : t('PHONE_WIDGET.MUTE_MICROPHONE')
);

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
    router?.push?.({
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
    :class="
      props.embedded
        ? 'flex flex-col divide-y divide-n-weak border-b border-n-weak'
        : 'fixed ltr:right-4 rtl:left-4 bottom-20 z-50 flex flex-col gap-2 w-72'
    "
    :data-testid="
      props.embedded ? 'phone-widget-whatsapp-calls' : 'whatsapp-calls'
    "
  >
    <!-- Error banner -->
    <div
      v-if="callError"
      class="px-3 py-2 bg-n-ruby-3 border border-n-ruby-6 text-xs text-n-ruby-11"
      :class="props.embedded ? 'mx-4 my-2 rounded-md' : 'rounded-lg'"
      data-testid="whatsapp-call-error"
    >
      {{ callError }}
    </div>

    <!-- Incoming calls remain visible while the operator is busy. -->
    <template v-if="visibleIncomingCalls.length">
      <div
        v-for="call in visibleIncomingCalls"
        :key="call.callId"
        class="relative flex items-center gap-3"
        :class="
          props.embedded
            ? 'px-4 py-3'
            : 'p-4 ltr:pr-12 rtl:pl-12 bg-n-solid-2 rounded-xl shadow-xl outline outline-1 outline-n-strong'
        "
        :data-testid="props.embedded ? 'phone-widget-call-card' : undefined"
        data-call-channel="whatsapp"
        :data-own-call="props.embedded ? 'true' : undefined"
      >
        <button
          v-if="!props.embedded"
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
          <div class="flex items-center gap-1.5 min-w-0">
            <i
              class="i-ri-whatsapp-fill text-n-teal-9 text-sm shrink-0"
              aria-hidden="true"
            />
            <p class="text-sm font-medium text-n-slate-12 truncate mb-0">
              {{
                call.caller?.name ||
                call.caller?.phone ||
                t('WHATSAPP_CALL.UNKNOWN_CALLER')
              }}
            </p>
          </div>
          <div class="flex items-center justify-between gap-1 mt-0.5">
            <p class="text-xs text-n-slate-11 truncate mb-0">
              {{ t('WHATSAPP_CALL.INCOMING_WHATSAPP_CALL') }}
            </p>
            <button
              v-if="props.embedded"
              type="button"
              class="shrink-0 inline-flex items-center gap-0.5 rounded px-1.5 py-0.5 text-[11px] font-medium text-n-slate-11 hover:bg-n-alpha-2 hover:text-n-slate-12 transition-colors"
              data-testid="floating-call-context-toggle"
              @click="toggleCallCardExpanded"
            >
              <span>
                {{ isCallCardExpanded ? 'Компактный вид' : 'Подробный вид' }}
              </span>
              <i
                class="text-xs"
                :class="
                  isCallCardExpanded
                    ? 'i-lucide-chevron-up'
                    : 'i-lucide-chevron-down'
                "
              />
            </button>
          </div>
          <p
            v-if="
              isCallCardExpanded &&
              call.caller?.phone &&
              call.caller?.name &&
              call.caller.name !== call.caller.phone
            "
            class="text-xs text-n-slate-11 truncate mb-0 mt-0.5"
          >
            WhatsApp · {{ call.caller.phone }}
          </p>
          <!-- On a call, the employee cannot take another one for now. -->
          <p
            v-if="operatorBusy"
            class="text-xs text-n-slate-11 mb-0"
            data-testid="whatsapp-call-busy-note"
          >
            {{ t('CONVERSATION.VOICE_WIDGET.BUSY_ON_CALL') }}
          </p>
        </div>
        <div class="flex shrink-0 gap-2">
          <button
            class="flex justify-center items-center w-10 h-10 bg-n-ruby-9 hover:bg-n-ruby-10 rounded-full transition-colors"
            :title="t('WHATSAPP_CALL.REJECT')"
            :aria-label="t('WHATSAPP_CALL.REJECT')"
            @click="handleReject(call)"
          >
            <i class="text-lg text-white i-ph-phone-x-bold" />
          </button>
          <button
            class="flex justify-center items-center w-10 h-10 bg-n-teal-9 hover:bg-n-teal-10 rounded-full transition-colors"
            :disabled="isAccepting || operatorBusy"
            :title="t('WHATSAPP_CALL.ACCEPT')"
            :aria-label="t('WHATSAPP_CALL.ACCEPT')"
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
      class="relative flex items-center gap-3"
      :class="
        props.embedded
          ? 'px-4 py-3'
          : 'p-4 ltr:pr-12 rtl:pl-12 bg-n-solid-2 rounded-xl shadow-xl outline outline-1 outline-n-strong'
      "
      :data-testid="props.embedded ? 'phone-widget-call-card' : undefined"
      data-call-channel="whatsapp"
      :data-own-call="props.embedded ? 'true' : undefined"
    >
      <button
        v-if="!props.embedded"
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
        <div class="flex items-center gap-1.5 min-w-0">
          <i
            class="i-ri-whatsapp-fill text-n-teal-9 text-sm shrink-0"
            aria-hidden="true"
          />
          <p class="text-sm font-medium text-n-slate-12 truncate mb-0">
            {{
              activeCall.caller?.name ||
              activeCall.caller?.phone ||
              t('WHATSAPP_CALL.UNKNOWN_CALLER')
            }}
          </p>
        </div>
        <div class="flex items-center justify-between gap-1">
          <p
            class="text-sm mb-0"
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
          <button
            v-if="props.embedded"
            type="button"
            class="shrink-0 inline-flex items-center gap-0.5 rounded px-1.5 py-0.5 text-[11px] font-medium text-n-slate-11 hover:bg-n-alpha-2 hover:text-n-slate-12 transition-colors"
            data-testid="floating-call-context-toggle"
            @click="toggleCallCardExpanded"
          >
            <span>
              {{ isCallCardExpanded ? 'Компактный вид' : 'Подробный вид' }}
            </span>
            <i
              class="text-xs"
              :class="
                isCallCardExpanded
                  ? 'i-lucide-chevron-up'
                  : 'i-lucide-chevron-down'
              "
            />
          </button>
        </div>
        <p
          v-if="
            isCallCardExpanded &&
            activeCall.caller?.phone &&
            activeCall.caller?.name &&
            activeCall.caller.name !== activeCall.caller.phone
          "
          class="text-xs text-n-slate-11 truncate mb-0 mt-0.5"
        >
          WhatsApp · {{ activeCall.caller.phone }}
        </p>
        <p
          v-if="isMuted"
          class="mt-1 mb-0 inline-flex items-center gap-1 rounded-md bg-n-ruby-9 px-1.5 py-0.5 text-xs font-medium text-white"
          data-testid="call-microphone-off"
        >
          <i class="i-ph-microphone-slash-bold text-sm" aria-hidden="true" />
          {{ t('PHONE_WIDGET.MICROPHONE_OFF') }}
        </p>
      </div>
      <div class="flex shrink-0 gap-2">
        <!-- Mute toggle: muted is a filled red pressed button with its own
             label, like the microphone of the phone widget. -->
        <button
          type="button"
          class="flex justify-center items-center w-9 h-9 rounded-full transition-colors"
          :class="
            isMuted
              ? 'bg-n-ruby-9 text-white hover:bg-n-ruby-10 shadow-sm'
              : 'bg-n-alpha-2 text-n-slate-12 hover:bg-n-alpha-1'
          "
          :title="microphoneLabel"
          :aria-label="microphoneLabel"
          :aria-pressed="isMuted"
          data-testid="whatsapp-call-microphone"
          @click="toggleMute"
        >
          <i
            class="text-base"
            :class="
              isMuted ? 'i-ph-microphone-slash-bold' : 'i-ph-microphone-bold'
            "
          />
        </button>
        <!-- Hang up -->
        <button
          class="flex justify-center items-center w-9 h-9 bg-n-ruby-9 hover:bg-n-ruby-10 rounded-full transition-colors"
          :title="t('WHATSAPP_CALL.HANG_UP')"
          :aria-label="t('WHATSAPP_CALL.HANG_UP')"
          @click="handleEndCall"
        >
          <i class="text-base text-white i-ph-phone-x-bold" />
        </button>
      </div>
    </div>
  </div>
</template>
