<script setup>
import { computed, watch } from 'vue';
import { useI18n } from 'vue-i18n';
import { useRouter } from 'vue-router';
import { useStore } from 'vuex';
import { useAlert } from 'dashboard/composables';
import { useCallSession } from 'dashboard/composables/useCallSession';
import WindowVisibilityHelper from 'dashboard/helper/AudioAlerts/WindowVisibilityHelper';
import {
  getOutboundCallStageLabelKey,
  OUTBOUND_CALL_STAGE_LABEL_KEYS,
} from 'dashboard/helper/voiceCallStage';
import Avatar from 'dashboard/components-next/avatar/Avatar.vue';

const router = useRouter();
const store = useStore();
const { t } = useI18n();

const {
  activeCall,
  incomingCalls,
  hasActiveCall,
  isJoining,
  canHandleCallInBrowser,
  joinCall,
  endCall: endCallSession,
  rejectIncomingCall,
  dismissCall,
  formattedCallDuration,
} = useCallSession();

const isOutboundCall = call => call?.callDirection === 'outbound';
const visibleCalls = computed(() =>
  hasActiveCall.value
    ? [activeCall.value, ...incomingCalls.value].filter(Boolean)
    : incomingCalls.value.slice(0, 1)
);

const firstPresent = values => values.find(value => Boolean(value));

const getConversationAttributes = conversation =>
  conversation?.additional_attributes ||
  conversation?.additionalAttributes ||
  {};

const getCallInfo = call => {
  const conversation = store.getters.getConversationById(call?.conversationId);
  const inbox = store.getters['inboxes/getInbox'](
    call?.inboxId || conversation?.inbox_id
  );
  const sender = conversation?.meta?.sender;
  const caller = call?.caller || {};
  const provider = call?.provider || inbox?.provider;
  return {
    conversation,
    inbox,
    provider,
    contactName:
      sender?.name ||
      sender?.phone_number ||
      caller?.name ||
      caller?.phone_number ||
      caller?.phone ||
      t('CONVERSATION.VOICE_WIDGET.UNKNOWN_CALLER'),
    inboxName: inbox?.name || t('CONVERSATION.VOICE_WIDGET.DEFAULT_INBOX_NAME'),
    avatar: sender?.avatar || sender?.thumbnail || caller?.avatar,
  };
};

const isWhatsappCall = call => {
  const info = getCallInfo(call);
  const channelType = info.inbox?.channel_type || info.inbox?.channelType || '';
  const provider = info.provider || '';

  return [channelType, provider].some(value =>
    value.toString().toLowerCase().includes('whatsapp')
  );
};

const channelIconClass = call =>
  isWhatsappCall(call) ? 'i-ri-whatsapp-fill' : 'i-ri-phone-fill';

const callIsActive = call =>
  Boolean(
    activeCall.value?.callSid && activeCall.value.callSid === call?.callSid
  );

const browserJoinSupportedForCall = call => {
  return canHandleCallInBrowser({
    ...call,
    provider: call?.provider || getCallInfo(call)?.provider,
  });
};

const getDirectionLabel = call => {
  if (isOutboundCall(call)) {
    return t('CONVERSATION.VOICE_WIDGET.OUTBOUND_DIRECTION');
  }

  return t('CONVERSATION.VOICE_WIDGET.INBOUND_DIRECTION');
};

const getCallParties = call => {
  const info = getCallInfo(call);
  const conversationAttributes = getConversationAttributes(info.conversation);
  const fromNumber = firstPresent([
    call?.fromNumber,
    call?.from_number,
    conversationAttributes.from_number,
    conversationAttributes.fromNumber,
  ]);
  const toNumber = firstPresent([
    call?.toNumber,
    call?.to_number,
    conversationAttributes.to_number,
    conversationAttributes.toNumber,
  ]);
  const callerNumber = firstPresent([
    call?.caller?.phone_number,
    call?.caller?.phoneNumber,
    call?.caller?.phone,
  ]);
  const lineParty = isOutboundCall(call)
    ? firstPresent([fromNumber, info.inboxName])
    : firstPresent([toNumber, info.inboxName]);
  const customerParty = isOutboundCall(call)
    ? firstPresent([toNumber, info.contactName])
    : firstPresent([fromNumber, callerNumber, info.contactName]);

  return {
    lineParty,
    customerParty,
    from: isOutboundCall(call) ? lineParty : customerParty,
    to: isOutboundCall(call) ? customerParty : lineParty,
  };
};

const getCallRouteParts = call => {
  const parties = getCallParties(call);

  return {
    from: parties.from,
    to: parties.to,
  };
};

const getCallTypeText = call => {
  if (!browserJoinSupportedForCall(call)) {
    return t('CONVERSATION.VOICE_WIDGET.HANDLED_OUTSIDE_BROWSER');
  }

  return getDirectionLabel(call);
};

const getCallStageText = call => {
  if (!browserJoinSupportedForCall(call) || !isOutboundCall(call)) {
    return '';
  }

  switch (getOutboundCallStageLabelKey(call)) {
    case OUTBOUND_CALL_STAGE_LABEL_KEYS.CONNECTING_OPERATOR:
      return t('CONVERSATION.VOICE_WIDGET.OUTGOING_CONNECTING_OPERATOR');
    case OUTBOUND_CALL_STAGE_LABEL_KEYS.CALLING_CUSTOMER:
      return t('CONVERSATION.VOICE_WIDGET.OUTGOING_CALLING_CUSTOMER');
    case OUTBOUND_CALL_STAGE_LABEL_KEYS.CUSTOMER_RINGING:
      return t('CONVERSATION.VOICE_WIDGET.OUTGOING_CLIENT_RINGING');
    case OUTBOUND_CALL_STAGE_LABEL_KEYS.IN_PROGRESS:
      return t('CONVERSATION.VOICE_WIDGET.CALL_IN_PROGRESS');
    default:
      return '';
  }
};

const getCallSecondaryText = call => {
  const typeText = getCallTypeText(call);
  const stageText = getCallStageText(call);

  return stageText ? `${typeText} · ${stageText}` : typeText;
};

const idleCallDuration = '00:00';

const openConversation = call => {
  if (!call?.conversationId) return;

  const { conversation } = getCallInfo(call);
  const inboxId = call.inboxId || conversation?.inbox_id;
  const accountId = router.currentRoute.value.params?.accountId;
  const routeName = inboxId
    ? 'conversation_through_inbox'
    : 'inbox_conversation';
  const routeParams = {
    accountId,
    conversation_id: call.conversationId,
    ...(inboxId ? { inbox_id: inboxId } : {}),
  };

  const currentParams = router.currentRoute.value.params || {};
  const sameConversation =
    String(currentParams.conversation_id) === String(call.conversationId);
  const sameInbox =
    !inboxId || String(currentParams.inbox_id) === String(inboxId);

  if (
    router.currentRoute.value.name === routeName &&
    sameConversation &&
    sameInbox
  ) {
    return;
  }

  router.push({
    name: routeName,
    params: routeParams,
  });
};

const handleBrowserJoinUnavailable = (call, { notify = true } = {}) => {
  if (notify) {
    useAlert(t('CONVERSATION.VOICE_WIDGET.BROWSER_CALLING_UNAVAILABLE'));
  }

  openConversation(call);
};

const handleEndCall = async () => {
  const call = activeCall.value;
  if (!call) return;

  const inboxId = call.inboxId || getCallInfo(call).conversation?.inbox_id;
  const provider = call.provider || getCallInfo(call).provider;
  if (provider === 'twilio' && !inboxId) return;

  await endCallSession({
    conversationId: call.conversationId,
    inboxId,
    provider,
    callSid: call.callSid,
  });
};

const handleJoinCall = async (call, { notifyOnUnavailable = true } = {}) => {
  const { conversation } = getCallInfo(call);
  if (!call || isJoining.value) return;

  if (!browserJoinSupportedForCall(call)) {
    handleBrowserJoinUnavailable(call, { notify: notifyOnUnavailable });
    return;
  }

  const inboxId = call.inboxId || conversation?.inbox_id;
  if (!inboxId) return;

  // End current active call before joining new one
  if (hasActiveCall.value) {
    await handleEndCall();
  }

  const result = await joinCall({
    conversationId: call.conversationId,
    inboxId,
    callSid: call.callSid,
    provider: call.provider || getCallInfo(call).provider,
    callDirection: call.callDirection,
  });

  if (result?.joinSupported === false) {
    if (isOutboundCall(call)) return;

    handleBrowserJoinUnavailable(call, { notify: notifyOnUnavailable });
    return;
  }

  if (result) {
    openConversation(call);
  }
};

// Auto-join outbound calls when window is visible
watch(
  () => incomingCalls.value[0],
  call => {
    if (
      call?.callDirection === 'outbound' &&
      !call?.browserJoined &&
      !hasActiveCall.value &&
      WindowVisibilityHelper.isWindowVisible()
    ) {
      handleJoinCall(call, { notifyOnUnavailable: false });
    }
  },
  { immediate: true }
);
</script>

<template>
  <div class="contents">
    <template v-if="incomingCalls.length || hasActiveCall">
      <div
        class="fixed ltr:right-4 rtl:left-4 bottom-4 z-50 flex flex-col gap-2 w-[340px] max-w-[calc(100vw-2rem)]"
      >
        <div
          v-for="call in visibleCalls"
          :key="call.callSid"
          class="flex gap-1 p-3 bg-n-solid-2 rounded-lg shadow-xl outline outline-1 outline-n-strong"
        >
          <div class="flex flex-col items-center w-14 shrink-0 gap-1.5">
            <span
              class="inline-flex rounded-full"
              :class="{
                'ring-2 ring-n-teal-9': callIsActive(call),
                'animate-pulse ring-2 ring-n-teal-9': !callIsActive(call),
              }"
            >
              <Avatar
                :src="getCallInfo(call).avatar"
                :name="getCallInfo(call).contactName"
                :size="40"
                rounded-full
              />
            </span>
            <span
              class="font-mono leading-4 tabular-nums text-[13px] font-medium text-n-teal-9"
            >
              {{
                callIsActive(call) ? formattedCallDuration : idleCallDuration
              }}
            </span>
          </div>
          <div class="flex-1 min-w-0">
            <div class="flex items-start gap-2 min-w-0">
              <i
                class="mt-0.5 text-[14px] shrink-0"
                :class="[
                  channelIconClass(call),
                  isWhatsappCall(call) ? 'text-n-teal-9' : 'channel-icon-voice',
                ]"
              />
              <p
                class="min-w-0 flex-1 inline-flex items-center text-sm font-medium mb-0"
              >
                <span class="truncate">{{ getCallRouteParts(call).from }}</span>
                <span class="mx-1 text-[10px] font-normal text-n-slate-11">
                  {{ $t('CONVERSATION.VOICE_WIDGET.ROUTE_SEPARATOR') }}
                </span>
                <span class="truncate">{{ getCallRouteParts(call).to }}</span>
              </p>
              <button
                v-if="!callIsActive(call)"
                type="button"
                class="flex justify-center items-center text-n-slate-10 hover:text-n-slate-12 hover:bg-n-alpha-2 rounded-md transition-colors shrink-0"
                :title="$t('CONVERSATION.VOICE_WIDGET.CLOSE')"
                :aria-label="$t('CONVERSATION.VOICE_WIDGET.CLOSE')"
                @click="dismissCall(call.callSid)"
              >
                <i class="text-sm i-lucide-x" />
              </button>
            </div>

            <p class="mt-0.5 text-xs text-n-slate-11 truncate mb-0">
              {{ getCallSecondaryText(call) }}
            </p>

            <div class="flex items-center gap-3 mt-2.5">
              <button
                v-if="callIsActive(call)"
                type="button"
                class="inline-flex items-center justify-center w-11 h-11 rounded-full transition-colors bg-n-ruby-9 text-white hover:bg-n-ruby-10 shadow-sm"
                :title="$t('CONVERSATION.VOICE_WIDGET.END_CALL')"
                :aria-label="$t('CONVERSATION.VOICE_WIDGET.END_CALL')"
                @click="handleEndCall"
              >
                <i class="text-lg i-ph-phone-x-bold" />
              </button>
              <button
                v-if="
                  !callIsActive(call) &&
                  !isOutboundCall(call) &&
                  browserJoinSupportedForCall(call)
                "
                type="button"
                class="inline-flex items-center justify-center w-11 h-11 rounded-full transition-colors bg-n-teal-9 text-white hover:bg-n-teal-10 shadow-sm"
                :title="$t('CONVERSATION.VOICE_WIDGET.CALL')"
                :aria-label="$t('CONVERSATION.VOICE_WIDGET.CALL')"
                @click="handleJoinCall(call)"
              >
                <i class="text-lg i-ph-phone-bold" />
              </button>
              <button
                v-if="!callIsActive(call)"
                type="button"
                class="inline-flex items-center justify-center w-11 h-11 rounded-full transition-colors bg-n-ruby-9 text-white hover:bg-n-ruby-10 shadow-sm"
                :title="$t('CONVERSATION.VOICE_WIDGET.REJECT_CALL')"
                :aria-label="$t('CONVERSATION.VOICE_WIDGET.REJECT_CALL')"
                @click="rejectIncomingCall(call)"
              >
                <i class="text-lg i-ph-phone-x-bold" />
              </button>
              <button
                type="button"
                class="inline-flex items-center justify-center w-11 h-11 rounded-full transition-colors bg-n-alpha-2 text-n-slate-12 hover:bg-n-alpha-1"
                :title="$t('CONVERSATION.VOICE_WIDGET.OPEN_CHAT')"
                :aria-label="$t('CONVERSATION.VOICE_WIDGET.OPEN_CHAT')"
                @click="openConversation(call)"
              >
                <i class="text-lg i-ph-chat-circle-bold" />
              </button>
            </div>
          </div>
        </div>
      </div>
    </template>
  </div>
</template>
