<script setup>
import { watch } from 'vue';
import { useI18n } from 'vue-i18n';
import { useRouter } from 'vue-router';
import { useStore } from 'vuex';
import { useAlert } from 'dashboard/composables';
import { useCallSession } from 'dashboard/composables/useCallSession';
import WindowVisibilityHelper from 'dashboard/helper/AudioAlerts/WindowVisibilityHelper';
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
  formattedCallDuration,
} = useCallSession();

const formatProviderLabel = provider =>
  provider ? provider.replaceAll('_', ' ').toUpperCase() : '';

const formatInboxLine = ({ inboxName, providerLabel }) =>
  providerLabel ? `${inboxName} · ${providerLabel}` : inboxName;

const isOutboundCall = call => call?.callDirection === 'outbound';

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

const browserJoinSupportedForCall = call => {
  return canHandleCallInBrowser({
    ...call,
    provider: call?.provider || getCallInfo(call)?.provider,
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
        class="fixed ltr:right-4 rtl:left-4 bottom-4 z-50 flex flex-col gap-2 w-72"
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
            <p class="text-xs text-n-slate-11 truncate">
              {{ formatInboxLine(getCallInfo(call)) }}
            </p>
          </div>
          <div class="flex shrink-0 gap-2">
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
              :src="getCallInfo(activeCall || incomingCalls[0]).avatar"
              :name="getCallInfo(activeCall || incomingCalls[0]).contactName"
              :size="40"
              rounded-full
            />
          </div>
          <div class="flex-1 min-w-0">
            <p class="text-sm font-medium text-n-slate-12 truncate mb-0">
              {{ getCallInfo(activeCall || incomingCalls[0]).contactName }}
            </p>
            <p v-if="hasActiveCall" class="font-mono text-sm text-n-teal-9">
              {{ formattedCallDuration }}
            </p>
            <p v-else class="text-xs text-n-slate-11">
              {{
                browserJoinSupportedForCall(incomingCalls[0])
                  ? incomingCalls[0]?.callDirection === 'outbound'
                    ? $t('CONVERSATION.VOICE_WIDGET.OUTGOING_CALL')
                    : $t('CONVERSATION.VOICE_WIDGET.INCOMING_CALL')
                  : $t('CONVERSATION.VOICE_WIDGET.HANDLED_OUTSIDE_BROWSER')
              }}
            </p>
          </div>
          <div class="flex shrink-0 gap-2">
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
