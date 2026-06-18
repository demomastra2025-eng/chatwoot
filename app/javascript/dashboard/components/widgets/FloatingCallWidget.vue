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
  outboundCallStageShowsDuration,
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

const formatProviderLabel = provider =>
  provider ? provider.replaceAll('_', ' ').toUpperCase() : '';

const formatInboxLine = ({ inboxName, providerLabel }) =>
  providerLabel ? `${inboxName} · ${providerLabel}` : inboxName;

const isOutboundCall = call => call?.callDirection === 'outbound';
const primaryCall = computed(() => activeCall.value || incomingCalls.value[0]);

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
    providerLabel: formatProviderLabel(provider),
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

const browserJoinSupportedForCall = call => {
  return canHandleCallInBrowser({
    ...call,
    provider: call?.provider || getCallInfo(call)?.provider,
  });
};

const getAgentNameById = userId => {
  if (!userId) return '';

  return store.getters['agents/getAgentById']?.(userId)?.name || '';
};

const getOperatorName = call => {
  const claim = call?.operatorClaim || {};
  const userId = claim.user_id || claim.userId;

  return firstPresent([
    claim.user_name,
    claim.userName,
    claim.name,
    getAgentNameById(userId),
    claim.agent_ref,
    claim.agentRef,
    claim.agent_aor,
    claim.agentAor,
  ]);
};

const getHandledByText = call => {
  if (browserJoinSupportedForCall(call)) return '';

  const operatorName = getOperatorName(call);
  return operatorName
    ? t('CONVERSATION.VOICE_WIDGET.HANDLED_BY', { name: operatorName })
    : t('CONVERSATION.VOICE_WIDGET.HANDLED_BY_UNKNOWN');
};

const getDirectionLabel = call => {
  if (isOutboundCall(call)) {
    return t('CONVERSATION.VOICE_WIDGET.OUTBOUND_DIRECTION');
  }

  return t('CONVERSATION.VOICE_WIDGET.INBOUND_DIRECTION');
};

const getCallRouteText = call => {
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

  return t('CONVERSATION.VOICE_WIDGET.CALL_ROUTE', {
    from: isOutboundCall(call) ? lineParty : customerParty,
    to: isOutboundCall(call) ? customerParty : lineParty,
  });
};

const getCallDirectionRouteText = call =>
  t('CONVERSATION.VOICE_WIDGET.CALL_DIRECTION_ROUTE', {
    direction: getDirectionLabel(call),
    route: getCallRouteText(call),
  });

const getOutboundStageText = call => {
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

const getCallStatusText = call => {
  if (!call) return '';
  if (!browserJoinSupportedForCall(call)) {
    return t('CONVERSATION.VOICE_WIDGET.HANDLED_OUTSIDE_BROWSER');
  }
  if (isOutboundCall(call)) return getOutboundStageText(call);
  return t('CONVERSATION.VOICE_WIDGET.INCOMING_CALL');
};

const outboundStageShowsDuration = call => outboundCallStageShowsDuration(call);

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
        class="fixed ltr:right-4 rtl:left-4 bottom-4 z-50 flex flex-col gap-2 w-80 max-w-[calc(100vw-2rem)]"
      >
        <!-- Incoming Calls (shown above active call) -->
        <div
          v-for="call in hasActiveCall ? incomingCalls : []"
          :key="call.callSid"
          class="flex items-center gap-3 p-4 bg-n-solid-2 rounded-xl shadow-xl outline outline-1 outline-n-strong"
        >
          <div
            class="animate-pulse ring-2 ring-n-teal-9 rounded-full inline-flex"
          >
            <Avatar
              :src="getCallInfo(call).avatar"
              :name="getCallInfo(call).contactName"
              :size="40"
              rounded-full
            />
          </div>
          <div class="flex-1 min-w-0">
            <p class="text-sm font-medium text-n-slate-12 truncate mb-0">
              {{ getCallInfo(call).contactName }}
            </p>
            <p class="text-xs text-n-slate-11 truncate mb-0">
              {{ formatInboxLine(getCallInfo(call)) }}
            </p>
            <p class="text-[11px] text-n-slate-10 truncate mb-0">
              {{ getCallDirectionRouteText(call) }}
            </p>
            <p
              v-if="getHandledByText(call)"
              class="text-[11px] font-medium text-n-amber-11 truncate mb-0"
            >
              {{ getHandledByText(call) }}
            </p>
          </div>
          <div class="flex shrink-0 gap-2">
            <button
              type="button"
              class="flex justify-center items-center w-8 h-8 text-n-slate-11 hover:text-n-slate-12 hover:bg-n-alpha-2 rounded-full transition-colors"
              :title="$t('CONVERSATION.VOICE_WIDGET.CLOSE')"
              :aria-label="$t('CONVERSATION.VOICE_WIDGET.CLOSE')"
              @click="dismissCall(call.callSid)"
            >
              <i class="text-base i-lucide-x" />
            </button>
            <button
              class="flex justify-center items-center w-10 h-10 bg-n-ruby-9 hover:bg-n-ruby-10 rounded-full transition-colors"
              @click="rejectIncomingCall(call)"
            >
              <i class="text-lg text-white i-ph-phone-x-bold" />
            </button>
            <button
              class="flex justify-center items-center w-10 h-10 bg-n-teal-9 hover:bg-n-teal-10 rounded-full transition-colors"
              @click="handleJoinCall(call)"
            >
              <i
                class="text-lg text-white"
                :class="
                  browserJoinSupportedForCall(call)
                    ? 'i-ph-phone-bold'
                    : 'i-ph-chat-circle-bold'
                "
              />
            </button>
          </div>
        </div>

        <!-- Main Call Widget -->
        <div
          v-if="hasActiveCall || incomingCalls.length"
          class="flex items-center gap-3 p-4 bg-n-solid-2 rounded-xl shadow-xl outline outline-1 outline-n-strong"
        >
          <div
            class="ring-2 ring-n-teal-9 rounded-full inline-flex"
            :class="{ 'animate-pulse': !hasActiveCall }"
          >
            <Avatar
              :src="getCallInfo(primaryCall).avatar"
              :name="getCallInfo(primaryCall).contactName"
              :size="40"
              rounded-full
            />
          </div>
          <div class="flex-1 min-w-0">
            <p class="text-sm font-medium text-n-slate-12 truncate mb-0">
              {{ getCallInfo(primaryCall).contactName }}
            </p>
            <p class="text-xs text-n-slate-11 truncate mb-0">
              {{ formatInboxLine(getCallInfo(primaryCall)) }}
            </p>
            <p class="text-[11px] text-n-slate-10 truncate mb-0">
              {{ getCallDirectionRouteText(primaryCall) }}
            </p>
            <p
              v-if="getHandledByText(primaryCall)"
              class="text-[11px] font-medium text-n-amber-11 truncate mb-0"
            >
              {{ getHandledByText(primaryCall) }}
            </p>
            <p
              v-if="hasActiveCall && !isOutboundCall(primaryCall)"
              class="font-mono text-sm text-n-teal-9 mb-0"
            >
              {{ formattedCallDuration }}
            </p>
            <div v-else-if="hasActiveCall" class="min-w-0">
              <p class="text-sm font-medium text-n-teal-9 truncate mb-0">
                {{ getOutboundStageText(primaryCall) }}
              </p>
              <p
                v-if="outboundStageShowsDuration(primaryCall)"
                class="font-mono text-xs text-n-slate-11 mb-0"
              >
                {{ formattedCallDuration }}
              </p>
            </div>
            <p v-else class="text-xs text-n-slate-11 mb-0">
              {{ getCallStatusText(primaryCall) }}
            </p>
          </div>
          <div class="flex shrink-0 gap-2">
            <button
              v-if="!hasActiveCall"
              type="button"
              class="flex justify-center items-center w-8 h-8 text-n-slate-11 hover:text-n-slate-12 hover:bg-n-alpha-2 rounded-full transition-colors"
              :title="$t('CONVERSATION.VOICE_WIDGET.CLOSE')"
              :aria-label="$t('CONVERSATION.VOICE_WIDGET.CLOSE')"
              @click="dismissCall(primaryCall?.callSid)"
            >
              <i class="text-base i-lucide-x" />
            </button>
            <button
              class="flex justify-center items-center w-10 h-10 bg-n-ruby-9 hover:bg-n-ruby-10 rounded-full transition-colors"
              @click="
                hasActiveCall
                  ? handleEndCall()
                  : rejectIncomingCall(incomingCalls[0])
              "
            >
              <i class="text-lg text-white i-ph-phone-x-bold" />
            </button>
            <button
              v-if="!hasActiveCall && !isOutboundCall(incomingCalls[0])"
              class="flex justify-center items-center w-10 h-10 bg-n-teal-9 hover:bg-n-teal-10 rounded-full transition-colors"
              @click="handleJoinCall(incomingCalls[0])"
            >
              <i
                class="text-lg text-white"
                :class="
                  browserJoinSupportedForCall(incomingCalls[0])
                    ? 'i-ph-phone-bold'
                    : 'i-ph-chat-circle-bold'
                "
              />
            </button>
          </div>
        </div>
      </div>
    </template>
  </div>
</template>
