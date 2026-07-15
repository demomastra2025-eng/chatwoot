<script setup>
import { computed, ref, useAttrs } from 'vue';
import { useI18n } from 'vue-i18n';
import { useRoute, useRouter } from 'vue-router';
import * as Sentry from '@sentry/vue';
import { useMapGetter, useStore } from 'dashboard/composables/store';
import { INBOX_TYPES } from 'dashboard/helper/inbox';
import { useAlert } from 'dashboard/composables';
import { frontendURL, conversationUrl } from 'dashboard/helper/URLHelper';
import { useCallsStore } from 'dashboard/stores/calls';
import { useWhatsappCallsStore } from 'dashboard/stores/whatsappCalls';
import WebphoneClient from 'dashboard/api/channel/voice/webphoneClient';
import { startOutboundBrowserCall } from 'dashboard/api/channel/voice/outboundCallCoordinator';

import Button from 'dashboard/components-next/button/Button.vue';
import Dialog from 'dashboard/components-next/dialog/Dialog.vue';

const props = defineProps({
  phone: { type: String, default: '' },
  contactId: { type: [String, Number], required: true },
  label: { type: String, default: '' },
  icon: { type: [String, Object, Function], default: '' },
  size: { type: String, default: 'sm' },
  tooltipLabel: { type: String, default: '' },
  inboxId: { type: [String, Number], default: null },
  disabled: { type: Boolean, default: false },
});
const emit = defineEmits(['callInitiated']);

defineOptions({ inheritAttrs: false });
const attrs = useAttrs();
const route = useRoute();
const router = useRouter();
const store = useStore();
const callsStore = useCallsStore();
const whatsappCallsStore = useWhatsappCallsStore();

const OUTBOUND_BROWSER_STAGE_RANK = {
  preparing: 0,
  call_sent: 1,
  calling: 1,
  ringing: 2,
  progress: 2,
  connected: 3,
  accepted: 3,
};

const outboundBrowserStageUpdate = stage => {
  if (stage === 'accepted') {
    return {
      status: 'in_progress',
      callEvent: 'callee_answered',
      callLeg: 'callee',
      rawStatus: 'answered',
      browserStartState: 'connected',
      answeredAt: new Date().toISOString(),
    };
  }
  if (['progress', 'ringing'].includes(stage)) {
    return {
      callEvent: 'callee_ringing',
      callLeg: 'callee',
      rawStatus: 'ringing',
      browserStartState: 'ringing',
    };
  }

  return {
    callEvent: 'operator_answered',
    browserStartState: 'calling',
  };
};

const applyOutboundBrowserJoinState = ({ callSid, provider, stage }) => {
  callsStore.markBrowserJoined(callSid, provider);

  const normalizedStage = stage || 'calling';
  const currentCall = callsStore.calls.find(
    call => String(call.callSid) === String(callSid)
  );
  const currentStage =
    currentCall?.browserStartState || currentCall?.browser_start_state;
  const currentRank = OUTBOUND_BROWSER_STAGE_RANK[currentStage] ?? -1;
  const nextRank = OUTBOUND_BROWSER_STAGE_RANK[normalizedStage] ?? 1;
  if (nextRank < currentRank) return;

  callsStore.addCall({
    callSid,
    provider,
    callDirection: 'outbound',
    ...outboundBrowserStageUpdate(normalizedStage),
  });
  if (normalizedStage === 'accepted') callsStore.setCallActive(callSid);
};

const { t } = useI18n();

const dialogRef = ref(null);
const isPreparingCall = ref(false);

const inboxesList = useMapGetter('inboxes/getInboxes');
const contactsUiFlags = useMapGetter('contacts/getUIFlags');

const voiceInboxes = computed(() =>
  (inboxesList.value || []).filter(
    inbox => inbox.channel_type === INBOX_TYPES.VOICE
  )
);
const candidateVoiceInboxes = computed(() => {
  if (!props.inboxId) return voiceInboxes.value;

  const selectedInbox = voiceInboxes.value.find(
    inbox => String(inbox.id) === String(props.inboxId)
  );

  return [
    selectedInbox || {
      id: props.inboxId,
      channel_type: INBOX_TYPES.VOICE,
    },
  ];
});
const hasVoiceInboxes = computed(() => candidateVoiceInboxes.value.length > 0);

// Unified behavior: hide when no phone
const shouldRender = computed(() => hasVoiceInboxes.value && !!props.phone);

const isInitiatingCall = computed(() => {
  return contactsUiFlags.value?.isInitiatingCall || false;
});
const hasOngoingBrowserCall = computed(() =>
  callsStore.calls.some(call => {
    const startState = call.browserStartState || call.browser_start_state;
    return (
      call.isActive ||
      (call.callDirection === 'outbound' &&
        (call.browserJoined ||
          ['preparing', 'calling', 'ringing'].includes(startState)))
    );
  })
);
const isCallButtonBusy = computed(
  () =>
    props.disabled ||
    isPreparingCall.value ||
    isInitiatingCall.value ||
    hasOngoingBrowserCall.value ||
    whatsappCallsStore.hasActiveCall ||
    whatsappCallsStore.isAccepting
);

const sameValue = (left, right) =>
  left !== undefined &&
  left !== null &&
  right !== undefined &&
  right !== null &&
  String(left) === String(right);

const selectedChatContactId = () => {
  const selectedChat = store.getters.getSelectedChat;
  return (
    selectedChat?.contact_id ||
    selectedChat?.contactId ||
    selectedChat?.meta?.sender?.id ||
    selectedChat?.meta?.sender?.contact_id ||
    selectedChat?.meta?.sender?.contactId ||
    null
  );
};

const currentCommunicationThreadId = () =>
  route.params?.communication_thread_id || route.params?.communicationThreadId;

const selectedChatCommunicationThreadId = () => {
  const selectedChat = store.getters.getSelectedChat;
  return (
    selectedChat?.communication_thread_id ||
    selectedChat?.communicationThreadId ||
    selectedChat?.communication_thread?.display_id ||
    selectedChat?.communicationThread?.displayId ||
    selectedChat?.communication_thread?.id ||
    selectedChat?.communicationThread?.id ||
    null
  );
};

const isCommunicationThreadRoute = () =>
  route.name === 'communication_thread_conversation' ||
  Boolean(currentCommunicationThreadId());

const navigateToConversation = response => {
  if (sameValue(selectedChatContactId(), props.contactId)) return;

  const accountId = route.params.accountId;
  const conversationId = response?.conversation_id || response;
  const communicationThreadId =
    response?.communication_thread_id || response?.communicationThreadId;
  if (conversationId && accountId) {
    if (communicationThreadId) {
      if (
        sameValue(currentCommunicationThreadId(), communicationThreadId) ||
        sameValue(selectedChatCommunicationThreadId(), communicationThreadId)
      ) {
        return;
      }

      const path = frontendURL(
        conversationUrl({
          accountId,
          id: communicationThreadId,
          communicationThread: true,
        })
      );
      router.push({ path });
      return;
    }

    if (isCommunicationThreadRoute()) return;

    if (
      String(route.params?.conversation_id || route.params?.conversationId) ===
      String(conversationId)
    ) {
      return;
    }

    const path = frontendURL(
      conversationUrl({
        accountId,
        id: conversationId,
      })
    );
    router.push({ path });
  }
};

const BROWSER_SIP_PROVIDERS = new Set(['asterisk_analog', 'sipuni', 'binotel']);

const isBrowserSipInbox = inbox => BROWSER_SIP_PROVIDERS.has(inbox?.provider);

const callSessionRouteMetadata = callSession => {
  const metadata = callSession?.metadata || {};
  return metadata.metadata || metadata.route_metadata || {};
};

const callSessionOperatorCandidates = callSession => {
  const routeMetadata = callSessionRouteMetadata(callSession);
  const candidates =
    routeMetadata.operator_candidates || callSession?.operator_candidates;
  return Array.isArray(candidates) ? candidates : null;
};

const callSessionOperatorInternalExtension = callSession => {
  const routeMetadata = callSessionRouteMetadata(callSession);
  return (
    routeMetadata.operator_internal_extension ||
    callSession?.operator_internal_extension ||
    routeMetadata.internal_extension ||
    callSession?.metadata?.operator_identity?.internal_extension ||
    null
  );
};

const prepareBrowserSipWebphone = async inbox => {
  if (!isBrowserSipInbox(inbox)) return { ready: true };

  const provider = inbox.provider;
  const webphoneScope = { provider, inboxId: inbox.id };
  const prewarmMicrophone = scope =>
    WebphoneClient.prewarmMicrophone(scope).catch(error => ({
      provider,
      prewarmed: false,
      reason: error?.name || 'microphone_unavailable',
    }));
  const microphonePrewarm = prewarmMicrophone(webphoneScope);

  const stopMicrophonePrewarm = scope =>
    WebphoneClient.stopMicrophonePrewarm(scope);

  try {
    const session = await WebphoneClient.initializeDevice(inbox.id, {
      native: true,
    });
    const sessionScope = {
      provider,
      inboxId: inbox.id,
      sessionKey: session?.sessionKey || session?.session_key,
      sipProfileId: session?.sipProfileId || session?.sip_profile_id,
    };
    let microphone = await microphonePrewarm;
    const browserJoinSupported =
      session?.browserJoinSupported ?? session?.browser_join_supported;
    if (browserJoinSupported === false) {
      stopMicrophonePrewarm(sessionScope);
      return { ready: true, browserJoinSupported: false, sessionScope };
    }

    if (!microphone) microphone = await prewarmMicrophone(sessionScope);

    const ready =
      session?.provider === provider &&
      session?.callingSupported !== false &&
      session?.registered !== false &&
      microphone?.prewarmed !== false;
    if (!ready) stopMicrophonePrewarm(sessionScope);
    return { ready, browserJoinSupported: true, sessionScope };
  } catch (error) {
    stopMicrophonePrewarm(webphoneScope);
    // eslint-disable-next-line no-console
    console.warn('Failed to prepare browser SIP webphone:', error);
    return { ready: false, sessionScope: webphoneScope };
  }
};

const startCall = async inbox => {
  if (isCallButtonBusy.value) return;

  isPreparingCall.value = true;
  let callInitiated = false;
  try {
    const webphonePreparation = await prepareBrowserSipWebphone(inbox);
    if (!webphonePreparation.ready) {
      useAlert(t('CONVERSATION.VOICE_WIDGET.BROWSER_CALLING_UNAVAILABLE'));
      return;
    }

    const response = await store.dispatch('contacts/initiateCall', {
      contactId: props.contactId,
      inboxId: inbox.id,
    });
    callInitiated = true;
    emit('callInitiated', response);
    const {
      call_sid: callSid,
      conversation_id: conversationId,
      communication_thread_id: communicationThreadId,
    } = response;
    const callSession = response?.call_session || response?.callSession || {};
    const browserJoinSupported =
      response?.browser_join_supported ?? response?.browserJoinSupported;
    const shouldStartBrowserSip =
      isBrowserSipInbox(inbox) &&
      webphonePreparation.browserJoinSupported !== false &&
      browserJoinSupported !== false;
    const sessionScope = webphonePreparation.sessionScope || {};
    const call = {
      callSid,
      status: 'created',
      callEvent: 'created',
      conversationId,
      communicationThreadId:
        communicationThreadId || response?.communicationThreadId,
      inboxId: inbox.id,
      provider: inbox.provider,
      callDirection: 'outbound',
      browserJoinSupported,
      browserStartState: shouldStartBrowserSip ? 'preparing' : null,
      janusSessionKey: sessionScope.sessionKey,
      sipProfileId: sessionScope.sipProfileId,
      fromNumber:
        callSession.from_number || callSession.fromNumber || inbox.phone_number,
      toNumber: callSession.to_number || callSession.toNumber || props.phone,
      operatorCandidates: callSessionOperatorCandidates(callSession),
      operatorInternalExtension:
        callSessionOperatorInternalExtension(callSession),
    };

    callsStore.addCall(call);
    useAlert(t('CONTACT_PANEL.CALL_INITIATED'));
    navigateToConversation(response);

    if (shouldStartBrowserSip) {
      try {
        await startOutboundBrowserCall({
          call,
          sessionScope,
          onJoined: result => {
            applyOutboundBrowserJoinState({
              callSid,
              provider: inbox.provider,
              stage: result?.stage,
            });
          },
          onFailed: () => callsStore.dismissCall(callSid),
        });
      } catch (error) {
        Sentry.captureException(error);
        useAlert(t('CONVERSATION.VOICE_WIDGET.OUTGOING_START_FAILED'));
      }
    }
  } catch (error) {
    if (callInitiated) {
      Sentry.captureException(error);
      return;
    }
    if (isBrowserSipInbox(inbox)) {
      WebphoneClient.stopMicrophonePrewarm({
        provider: inbox.provider,
        inboxId: inbox.id,
      });
    }
    const apiError = error?.message;
    useAlert(apiError || t('CONTACT_PANEL.CALL_FAILED'));
  } finally {
    isPreparingCall.value = false;
  }
};

const onClick = async () => {
  if (isCallButtonBusy.value) return;

  if (candidateVoiceInboxes.value.length > 1) {
    dialogRef.value?.open();
    return;
  }
  const [inbox] = candidateVoiceInboxes.value;
  await startCall(inbox);
};

const onPickInbox = async inbox => {
  dialogRef.value?.close();
  await startCall(inbox);
};
</script>

<template>
  <span class="contents">
    <Button
      v-if="shouldRender"
      v-tooltip.top-end="tooltipLabel || null"
      v-bind="attrs"
      :disabled="isCallButtonBusy"
      :is-loading="isCallButtonBusy"
      :label="label"
      :icon="icon"
      :size="size"
      @click="onClick"
    />

    <Dialog
      v-if="shouldRender && candidateVoiceInboxes.length > 1"
      ref="dialogRef"
      :title="$t('CONTACT_PANEL.VOICE_INBOX_PICKER.TITLE')"
      show-cancel-button
      :show-confirm-button="false"
      width="md"
    >
      <div class="flex flex-col gap-2">
        <button
          v-for="inbox in candidateVoiceInboxes"
          :key="inbox.id"
          type="button"
          class="flex items-center justify-between w-full px-4 py-2 text-left rounded-lg hover:bg-n-alpha-2"
          @click="onPickInbox(inbox)"
        >
          <div class="flex items-center gap-2">
            <span class="i-ri-phone-fill text-n-slate-10" />
            <div class="flex flex-col">
              <span class="text-sm text-n-slate-12">{{ inbox.name }}</span>
            </div>
          </div>
          <div class="flex items-center gap-2">
            <span
              class="rounded-md bg-n-alpha-2 px-2 py-1 text-[11px] font-medium uppercase tracking-wide text-n-slate-11"
            >
              {{ inbox.provider }}
            </span>
            <span v-if="inbox.phone_number" class="text-xs text-n-slate-10">
              {{ inbox.phone_number }}
            </span>
          </div>
        </button>
      </div>
    </Dialog>
  </span>
</template>
