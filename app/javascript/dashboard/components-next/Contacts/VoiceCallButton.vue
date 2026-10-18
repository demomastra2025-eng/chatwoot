<script setup>
import { computed, ref, useAttrs } from 'vue';
import { useI18n } from 'vue-i18n';
import * as Sentry from '@sentry/vue';
import { useMapGetter, useStore } from 'dashboard/composables/store';
import { INBOX_TYPES } from 'dashboard/helper/inbox';
import { useAlert } from 'dashboard/composables';
import { useCallsStore } from 'dashboard/stores/calls';
import {
  phoneLineProviderLabel,
  phoneWidgetStatusColor,
  usePhoneWidgetStore,
} from 'dashboard/stores/phoneWidget';
import { useWhatsappCallsStore } from 'dashboard/stores/whatsappCalls';
import WebphoneClient from 'dashboard/api/channel/voice/webphoneClient';
import ContactAPI from 'dashboard/api/contacts';
import { parsePhoneNumberFromString } from 'libphonenumber-js';
import { startOutboundBrowserCall } from 'dashboard/api/channel/voice/outboundCallCoordinator';

import Button from 'dashboard/components-next/button/Button.vue';
import Dialog from 'dashboard/components-next/dialog/Dialog.vue';

const props = defineProps({
  phone: { type: String, default: '' },
  contactId: { type: [String, Number], default: null },
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
const store = useStore();
const callsStore = useCallsStore();
const phoneWidgetStore = usePhoneWidgetStore();
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
  if (!props.inboxId) {
    const preferredId = phoneWidgetStore.selectedInboxId;
    if (preferredId === null || preferredId === undefined) {
      return voiceInboxes.value;
    }
    return [...voiceInboxes.value].sort((a, b) => {
      const aPreferred = String(a.id) === String(preferredId) ? 0 : 1;
      const bPreferred = String(b.id) === String(preferredId) ? 0 : 1;
      return aPreferred - bPreferred;
    });
  }

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

const BROWSER_SIP_PROVIDERS = new Set([
  'asterisk_analog',
  'sipuni',
  'binotel',
  'beeline',
  'wazo',
]);

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

const digitsOnly = number => String(number || '').replace(/\D/g, '');
const MAX_CONTACT_SEARCH_PAGES = 20;
const canonicalDialNumber = phone => {
  if (!/^\+?\d{3,20}$/.test(phone)) {
    throw new Error(t('PHONE_WIDGET.INVALID_NUMBER'));
  }
  const parsed = parsePhoneNumberFromString(phone, 'KZ');
  if (!parsed?.isValid()) throw new Error(t('PHONE_WIDGET.INVALID_NUMBER'));
  return parsed.number;
};
const findDialContactId = async (phone, page = 1) => {
  const { data } = await ContactAPI.search(digitsOnly(phone), page);
  const contact = (data?.payload || []).find(
    item => item.phone_number === phone
  );
  if (contact) return contact.id;
  if (!data?.meta?.has_more) return null;
  if (page === MAX_CONTACT_SEARCH_PAGES) {
    // Never create a duplicate while an exact contact may still exist.
    throw new Error(t('PHONE_WIDGET.CONTACT_LOOKUP_INCOMPLETE'));
  }
  return findDialContactId(phone, page + 1);
};
const resolveDialContactId = async () => {
  const phone = canonicalDialNumber(props.phone.trim());
  const contactId = await findDialContactId(phone);
  if (contactId) return contactId;
  const created = await store.dispatch('contacts/create', {
    name: phone,
    phoneNumber: phone,
  });
  return created.id;
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
    let session = await WebphoneClient.initializeDevice(inbox.id, {
      native: true,
      claimOwnership: true,
    });
    if (session?.registered === false && session?.callingSupported !== false) {
      // After a failed call or a network drop the phone registers again within
      // a few seconds: wait for that instead of giving up at once.
      session =
        (await WebphoneClient.waitForRegistration({
          provider,
          inboxId: inbox.id,
          sessionKey: session.sessionKey,
        })) || session;
    }
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

    const phoneReady =
      session?.provider === provider &&
      session?.callingSupported !== false &&
      session?.registered !== false;
    const microphoneReady = microphone?.prewarmed !== false;
    const ready = phoneReady && microphoneReady;
    if (!ready) stopMicrophonePrewarm(sessionScope);
    return {
      ready,
      // The phone is fine, only the microphone is not usable.
      microphoneBlocked: phoneReady && !microphoneReady,
      browserJoinSupported: true,
      sessionScope,
    };
  } catch (error) {
    stopMicrophonePrewarm(webphoneScope);
    // eslint-disable-next-line no-console
    console.warn('Failed to prepare browser SIP webphone:', error);
    return { ready: false, sessionScope: webphoneScope };
  }
};

const startCall = async inbox => {
  if (isCallButtonBusy.value) return;
  // One SIP handle carries one call: a call-back now would only fail.
  if (isBrowserSipInbox(inbox) && WebphoneClient.hasIncomingCallRinging()) {
    useAlert(t('CONVERSATION.VOICE_WIDGET.BROWSER_INCOMING_CALL_RINGING'));
    return;
  }

  isPreparingCall.value = true;
  // Shows the phone widget while the call is prepared, even if it is hidden.
  phoneWidgetStore.beginOutboundCall();
  let callInitiated = false;
  try {
    const contactId = props.contactId || (await resolveDialContactId());
    const webphonePreparation = await prepareBrowserSipWebphone(inbox);
    if (!webphonePreparation.ready) {
      useAlert(
        webphonePreparation.microphoneBlocked
          ? t('CONVERSATION.VOICE_WIDGET.BROWSER_MICROPHONE_UNAVAILABLE')
          : t('CONVERSATION.VOICE_WIDGET.BROWSER_CALLING_UNAVAILABLE')
      );
      return;
    }

    const response = await store.dispatch('contacts/initiateCall', {
      contactId,
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
    phoneWidgetStore.finishOutboundCall();
  }
};

const inboxLineStatus = inbox => {
  const fromStore = phoneWidgetStore.linesStatusById?.[String(inbox?.id)];
  if (fromStore) return fromStore;
  const sessions =
    typeof WebphoneClient.getSessions === 'function'
      ? WebphoneClient.getSessions() || []
      : [];
  const inboxSessions = sessions.filter(
    session => String(session?.inboxId) === String(inbox?.id)
  );
  if (inboxSessions.some(s => s?.registered && !s?.mirrored)) return 'ready';
  if (inboxSessions.some(s => s?.registered && s?.mirrored)) return 'ownerTab';
  if (inboxSessions.some(s => s?.callingSupported === false)) return 'error';
  if (isBrowserSipInbox(inbox)) return 'disconnected';
  return 'ready';
};

const inboxLineStatusDotClass = inbox =>
  phoneWidgetStatusColor(inboxLineStatus(inbox));

const inboxLineStatusLabel = inbox => {
  const status = inboxLineStatus(inbox);
  if (status === 'ready') return t('SIDEBAR.SIP_TELEPHONY.STATUS.READY');
  if (status === 'ownerTab')
    return t('SIDEBAR.SIP_TELEPHONY.STATUS.READY_IN_OWNER_TAB');
  if (status === 'connecting')
    return t('SIDEBAR.SIP_TELEPHONY.STATUS.CONNECTING');
  if (status === 'error') return t('SIDEBAR.SIP_TELEPHONY.STATUS.ERROR');
  return t('SIDEBAR.SIP_TELEPHONY.STATUS.DISCONNECTED');
};

const isPreferredInbox = inbox =>
  phoneWidgetStore.selectedInboxId !== null &&
  phoneWidgetStore.selectedInboxId !== undefined &&
  String(inbox?.id) === String(phoneWidgetStore.selectedInboxId);

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
  if (inbox?.id !== null && inbox?.id !== undefined) {
    phoneWidgetStore.setSelectedInboxId(inbox.id);
  }
  dialogRef.value?.close();
  await startCall(inbox);
};

defineExpose({ onClick });
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
      width="sm"
    >
      <div class="flex flex-col gap-1.5" data-testid="voice-inbox-picker-list">
        <button
          v-for="inbox in candidateVoiceInboxes"
          :key="inbox.id"
          type="button"
          class="flex w-full items-center justify-between gap-2 rounded-lg border px-3 py-1.5 text-left transition-colors"
          :class="
            isPreferredInbox(inbox)
              ? 'border-n-teal-9 bg-n-teal-2 hover:bg-n-teal-3'
              : 'border-n-weak hover:bg-n-alpha-2'
          "
          :data-inbox-id="String(inbox.id)"
          :data-selected="String(isPreferredInbox(inbox))"
          :data-line-status="inboxLineStatus(inbox)"
          data-testid="voice-inbox-picker-option"
          @click="onPickInbox(inbox)"
        >
          <div class="flex min-w-0 flex-1 items-center gap-2 overflow-hidden">
            <span
              class="size-2 shrink-0 rounded-full"
              :class="inboxLineStatusDotClass(inbox)"
              :title="inboxLineStatusLabel(inbox)"
              data-testid="voice-inbox-picker-status-dot"
            />
            <span class="i-ri-phone-fill shrink-0 text-xs text-n-slate-10" />
            <span
              class="min-w-0 flex-1 truncate text-xs font-medium text-n-slate-12"
            >
              {{ inbox.name }}
            </span>
            <span class="sr-only" data-testid="voice-inbox-picker-status">
              {{ inboxLineStatusLabel(inbox) }}
            </span>
          </div>
          <div class="flex shrink-0 items-center gap-1.5">
            <span
              v-if="
                inbox.phone_number &&
                !String(inbox.name || '').includes(inbox.phone_number)
              "
              class="text-[11px] tabular-nums text-n-slate-10"
            >
              {{ inbox.phone_number }}
            </span>
            <span
              class="rounded bg-n-alpha-2 px-1.5 py-0.5 text-[10px] font-medium text-n-slate-11"
              data-testid="voice-inbox-picker-provider"
            >
              {{ phoneLineProviderLabel(inbox) || inbox.provider }}
            </span>
            <span
              v-if="isPreferredInbox(inbox)"
              class="inline-flex size-4 shrink-0 items-center justify-center rounded-full bg-n-teal-3 text-n-teal-11"
              title="Выбрана для звонка"
              data-testid="voice-inbox-picker-selected-badge"
            >
              <i class="i-lucide-check text-[10px]" aria-hidden="true" />
              <span class="sr-only">Выбрана для звонка</span>
            </span>
          </div>
        </button>
      </div>
    </Dialog>
  </span>
</template>
