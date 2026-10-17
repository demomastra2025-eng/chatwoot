<script setup>
import { computed, onUnmounted, ref, watch } from 'vue';
import { useI18n } from 'vue-i18n';
import { useRouter } from 'vue-router';
import { useStore } from 'vuex';
import { useAlert } from 'dashboard/composables';
import { useCallSession } from 'dashboard/composables/useCallSession';
import { useIncomingCallAttention } from 'dashboard/composables/useIncomingCallAttention';
import { useIncomingCallRingtone } from 'dashboard/composables/useIncomingCallRingtone';
import { useSipMicrophone } from 'dashboard/composables/useSipMicrophone';
import { useWhatsappCallsStore } from 'dashboard/stores/whatsappCalls';
import {
  isCallOfAnotherParty,
  isEmployeeOwnCall,
} from 'dashboard/stores/calls';
import { isVoiceCallRingtoneEligible } from 'dashboard/helper/AudioAlerts/ringtone';
import {
  getOutboundCallStageLabelKey,
  OUTBOUND_CALL_STAGE_LABEL_KEYS,
  outboundCallStageShowsDuration,
} from 'dashboard/helper/voiceCallStage';
import Avatar from 'dashboard/components-next/avatar/Avatar.vue';

const props = defineProps({
  // Rendered as the call list inside the phone widget, so the phone is the
  // only call window. Standalone cards are kept for employees without a
  // browser SIP line (no phone widget).
  embedded: { type: Boolean, default: false },
  // The phone widget keeps its call list mounted while it is hidden so that
  // incoming calls are still reported; a hidden list never rings.
  silent: { type: Boolean, default: false },
});

const router = useRouter();
const store = useStore();
const whatsappCallsStore = useWhatsappCallsStore();
const { t } = useI18n();
const currentUserId = computed(() => store.getters.getCurrentUser?.id);

const {
  activeCall,
  incomingCalls,
  hasActiveCall,
  isJoining,
  canHandleCallInBrowser,
  isIncomingCallActionableInBrowser,
  joinCall,
  endCall: endCallSession,
  rejectIncomingCall,
  formattedCallDuration,
} = useCallSession();

const { microphoneAvailable, microphoneMuted, toggleMicrophone } =
  useSipMicrophone(activeCall);
const microphoneLabel = computed(() => {
  if (!microphoneAvailable.value) {
    return t('PHONE_WIDGET.MICROPHONE_UNAVAILABLE');
  }
  return microphoneMuted.value
    ? t('PHONE_WIDGET.MICROPHONE_MUTED')
    : t('PHONE_WIDGET.MUTE_MICROPHONE');
});

const operatorBusy = computed(
  () =>
    hasActiveCall.value ||
    whatsappCallsStore.hasActiveCall ||
    whatsappCallsStore.isAccepting
);

// What the server answers when the employee tries to take a call he cannot.
const CLAIM_FAILURE_ALERT_KEYS = {
  CALL_ALREADY_CLAIMED: 'CONVERSATION.VOICE_WIDGET.CALL_ALREADY_TAKEN',
  CALL_NOT_CLAIMABLE: 'CONVERSATION.VOICE_WIDGET.CALL_ALREADY_ENDED',
  OPERATOR_BUSY: 'CONVERSATION.VOICE_WIDGET.OPERATOR_BUSY',
};

const isOutboundCall = call => call?.callDirection === 'outbound';
const callCancelLabel = call =>
  isOutboundCall(call)
    ? t('CONVERSATION.VOICE_WIDGET.CANCEL_CALL')
    : t('CONVERSATION.VOICE_WIDGET.REJECT_CALL');
const ACTIVE_CALL_STATUSES = new Set([
  'answered',
  'accepted',
  'in_progress',
  'up',
]);
const hiddenCallSids = ref(new Set());
const callSidFor = call => (call?.callSid ? String(call.callSid) : '');
const logicalCallKeyFor = call =>
  call?.logicalCallKey ||
  call?.logical_call_key ||
  call?.callGroupKey ||
  call?.call_group_key;
const incomingPresentationKey = call => {
  const logicalCallKey = logicalCallKeyFor(call);
  if (!logicalCallKey || isOutboundCall(call)) return null;

  const provider = call?.provider || 'unknown';
  const inboxId = call?.inboxId || call?.inbox_id || 'unknown';
  return `${provider}:${inboxId}:${logicalCallKey}`;
};
const preferActionableIncomingBranch = (current, candidate) => {
  if (!current) return candidate;
  if (current?.isActive) return current;
  if (candidate?.isActive) return candidate;
  if (
    isIncomingCallActionableInBrowser(candidate) &&
    !isIncomingCallActionableInBrowser(current)
  ) {
    return candidate;
  }

  return current;
};
const deduplicateVisibleCalls = calls => {
  const groupedCalls = new Map();

  calls.forEach(call => {
    const key = incomingPresentationKey(call) || `call:${callSidFor(call)}`;
    groupedCalls.set(
      key,
      preferActionableIncomingBranch(groupedCalls.get(key), call)
    );
  });

  return [...groupedCalls.values()];
};
const elapsedNowMs = ref(Date.now());
const callFirstSeenAtMs = ref({});
let elapsedTimerId = null;
const trackedCallSids = computed(() =>
  [callSidFor(activeCall.value), ...incomingCalls.value.map(callSidFor)].filter(
    Boolean
  )
);
const isCallHidden = call => {
  const callSid = callSidFor(call);
  return callSid && hiddenCallSids.value.has(callSid);
};
// Only the employee's own calls get a card: a call another operator talks
// on, or the AI voice agent handles, is not shown (and can never be ended
// or declined from here).
const visibleCalls = computed(() =>
  deduplicateVisibleCalls(
    (hasActiveCall.value
      ? [activeCall.value, ...incomingCalls.value].filter(Boolean)
      : incomingCalls.value
    ).filter(
      call =>
        !isCallHidden(call) &&
        // A call this browser holds a live INVITE for is the employee's own.
        (!isCallOfAnotherParty(call, currentUserId.value) ||
          isIncomingCallActionableInBrowser(call))
    )
  )
);
const ringingCalls = computed(() =>
  props.silent || isJoining.value || operatorBusy.value
    ? []
    : visibleCalls.value.filter(
        call =>
          isVoiceCallRingtoneEligible(call) &&
          isIncomingCallActionableInBrowser(call)
      )
);
const shouldPlayIncomingCallRingtone = computed(
  () => ringingCalls.value.length > 0
);

useIncomingCallRingtone('voice', shouldPlayIncomingCallRingtone);

const firstPresent = values => values.find(value => Boolean(value));

const displayNameFrom = value => {
  if (!value) return '';
  if (typeof value === 'string') return value.trim();

  return (
    value.name ||
    value.displayName ||
    value.display_name ||
    value.userName ||
    value.user_name ||
    value.user?.name ||
    value.user?.displayName ||
    value.user?.display_name ||
    ''
  );
};

const getConversationAttributes = conversation =>
  conversation?.additional_attributes ||
  conversation?.additionalAttributes ||
  {};

const getCommunicationThreadId = (call, conversation) =>
  firstPresent([
    call?.communicationThreadId,
    call?.communication_thread_id,
    conversation?.communication_thread_id,
    conversation?.communicationThreadId,
    conversation?.meta?.communication_thread_id,
    conversation?.meta?.communicationThreadId,
    getConversationAttributes(conversation).communication_thread_id,
    getConversationAttributes(conversation).communicationThreadId,
  ]);

const concreteConversationRouteNames = new Set([
  'conversation',
  'inbox_conversation',
  'conversation_through_inbox',
]);

const getContactIdFromConversation = conversation =>
  firstPresent([
    conversation?.contact_id,
    conversation?.contactId,
    conversation?.meta?.sender?.id,
    conversation?.meta?.sender?.contact_id,
    conversation?.meta?.sender?.contactId,
  ]);

const getCallContactId = (call, conversation) =>
  firstPresent([
    call?.contactId,
    call?.contact_id,
    call?.caller?.id,
    call?.caller?.contact_id,
    call?.caller?.contactId,
    getContactIdFromConversation(conversation),
  ]);

const getSelectedChatContactId = () => {
  const selectedChat = store.getters.getSelectedChat;
  return getContactIdFromConversation(selectedChat);
};

const isCurrentConcreteConversationForCall = (call, conversation) => {
  const currentRoute = router.currentRoute.value;
  const currentParams = currentRoute.params || {};
  const currentConversationId =
    currentParams.conversation_id || currentParams.conversationId;
  if (
    currentConversationId &&
    call?.conversationId &&
    String(currentConversationId) === String(call.conversationId)
  ) {
    return true;
  }

  const routeName = currentRoute.name;
  const isConcreteRoute =
    concreteConversationRouteNames.has(routeName) ||
    (currentConversationId &&
      routeName !== 'communication_thread_conversation');
  if (!isConcreteRoute) return false;

  const contactId = getCallContactId(call, conversation);
  const selectedChatContactId = getSelectedChatContactId();
  return (
    contactId &&
    selectedChatContactId &&
    String(contactId) === String(selectedChatContactId)
  );
};

const isCurrentCommunicationThreadForCall = (call, conversation) => {
  if (router.currentRoute.value.name !== 'communication_thread_conversation') {
    return false;
  }

  const communicationThreadId = getCommunicationThreadId(call, conversation);
  const currentThreadId =
    router.currentRoute.value.params?.communication_thread_id ||
    router.currentRoute.value.params?.communicationThreadId;
  if (
    communicationThreadId &&
    currentThreadId &&
    String(communicationThreadId) === String(currentThreadId)
  ) {
    return true;
  }

  const contactId = getCallContactId(call, conversation);
  const selectedChatContactId = getSelectedChatContactId();
  return (
    contactId &&
    selectedChatContactId &&
    String(contactId) === String(selectedChatContactId)
  );
};

const communicationThreadQuery = () => {
  const currentQuery = router.currentRoute.value.query || {};
  return {
    ...currentQuery,
    status: currentQuery.status || 'open',
    assignee_type:
      currentQuery.assignee_type || currentQuery.assigneeType || 'all',
  };
};

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

const normalizeStatus = value =>
  value?.toString?.().trim().toLowerCase().replaceAll('-', '_') || '';

const callHasActiveRemoteState = call =>
  ACTIVE_CALL_STATUSES.has(normalizeStatus(call?.status)) ||
  Boolean(call?.answeredAt || call?.answered_at) ||
  (isOutboundCall(call) && outboundCallStageShowsDuration(call));

const callIsLiveActive = call =>
  callIsActive(call) || callHasActiveRemoteState(call);

// The browser microphone belongs to the connected call; while it is muted
// (from the phone header or the card button) the call says so in words.
const callMicrophoneOff = call =>
  microphoneMuted.value && callIsActive(call) && !isWhatsappCall(call);

const browserJoinSupportedForCall = call => {
  return canHandleCallInBrowser({
    ...call,
    provider: call?.provider || getCallInfo(call)?.provider,
  });
};

// While the employee is on a call he cannot take another one for now: the
// accept button of the second call is disabled and says why.
const showBusyNote = call =>
  operatorBusy.value &&
  !callIsLiveActive(call) &&
  !isOutboundCall(call) &&
  browserJoinSupportedForCall(call) &&
  isIncomingCallActionableInBrowser(call);

const getDirectionLabel = call => {
  if (isOutboundCall(call)) {
    return t('CONVERSATION.VOICE_WIDGET.OUTBOUND_DIRECTION');
  }

  return t('CONVERSATION.VOICE_WIDGET.INBOUND_DIRECTION');
};

const getOperatorCandidates = call => {
  const candidates = call?.operatorCandidates || call?.operator_candidates;
  return Array.isArray(candidates) ? candidates : [];
};

const sameOperatorIdentity = (left, right) =>
  left !== undefined &&
  left !== null &&
  left !== '' &&
  right !== undefined &&
  right !== null &&
  right !== '' &&
  String(left) === String(right);

const getPrimaryOperatorCandidate = call => {
  const candidates = getOperatorCandidates(call);
  const sipProfileId = firstPresent([call?.sipProfileId, call?.sip_profile_id]);
  const internalExtension = firstPresent([
    call?.operatorInternalExtension,
    call?.operator_internal_extension,
  ]);

  return (
    candidates.find(candidate =>
      sameOperatorIdentity(
        candidate?.sipProfileId || candidate?.sip_profile_id,
        sipProfileId
      )
    ) ||
    candidates.find(candidate =>
      sameOperatorIdentity(
        candidate?.internalExtension || candidate?.internal_extension,
        internalExtension
      )
    ) ||
    candidates[0] ||
    {}
  );
};

const getOperatorName = call => {
  const candidate = getPrimaryOperatorCandidate(call);
  return firstPresent([
    displayNameFrom(call?.operatorClaim),
    displayNameFrom(call?.operator_claim),
    displayNameFrom(candidate),
  ]);
};

const getOperatorExtension = call => {
  const candidate = getPrimaryOperatorCandidate(call);
  const claim = call?.operatorClaim || call?.operator_claim || {};

  return firstPresent([
    claim.internalExtension,
    claim.internal_extension,
    call?.operatorInternalExtension,
    call?.operator_internal_extension,
    candidate.internalExtension,
    candidate.internal_extension,
  ]);
};

const getOperatorParty = call => {
  const claim = call?.operatorClaim || call?.operator_claim || {};
  const name = displayNameFrom(claim);
  const extension = firstPresent([
    claim.internalExtension,
    claim.internal_extension,
  ]);

  if (name && extension) {
    return t('CONVERSATION.VOICE_WIDGET.OPERATOR_WITH_EXTENSION', {
      name,
      extension,
    });
  }
  if (name) return name;
  if (extension) {
    return t('CONVERSATION.VOICE_WIDGET.OPERATOR_EXTENSION', {
      extension,
    });
  }

  return '';
};

const getOperatorText = call => {
  const name = getOperatorName(call);
  const extension = getOperatorExtension(call);
  const party =
    name && extension
      ? t('CONVERSATION.VOICE_WIDGET.OPERATOR_WITH_EXTENSION', {
          name,
          extension,
        })
      : getOperatorParty(call);
  return party || '';
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
    const operator = getOperatorParty(call);
    if (callHasActiveRemoteState(call)) {
      return operator
        ? t('CONVERSATION.VOICE_WIDGET.HANDLED_BY', { name: operator })
        : t('CONVERSATION.VOICE_WIDGET.HANDLED_BY_UNKNOWN');
    }

    return t('CONVERSATION.VOICE_WIDGET.HANDLED_OUTSIDE_BROWSER');
  }

  if (call?.isActive || ACTIVE_CALL_STATUSES.has(call?.status)) {
    return t('CONVERSATION.VOICE_WIDGET.CALL_IN_PROGRESS');
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
  const operatorText =
    !browserJoinSupportedForCall(call) && callHasActiveRemoteState(call)
      ? ''
      : getOperatorText(call);
  const stageText = getCallStageText(call);

  return [typeText, operatorText, stageText].filter(Boolean).join(' · ');
};

const idleCallDuration = '00:00';
const timestampMs = value => {
  if (!value) return null;

  const numericValue = Number(value);
  if (Number.isFinite(numericValue) && numericValue > 0) {
    return numericValue < 1_000_000_000_000
      ? numericValue * 1000
      : numericValue;
  }

  const parsedValue = Date.parse(value);
  return Number.isFinite(parsedValue) ? parsedValue : null;
};

const firstTimestampMs = values => {
  const timestamps = values.map(timestampMs).filter(Boolean);
  return timestamps[0] || null;
};

const formatDuration = seconds => {
  const normalizedSeconds = Math.max(0, Number(seconds) || 0);
  const minutes = Math.floor(normalizedSeconds / 60);
  const restSeconds = normalizedSeconds % 60;
  return `${minutes.toString().padStart(2, '0')}:${restSeconds.toString().padStart(2, '0')}`;
};

const remoteCallDuration = call => {
  const callSid = callSidFor(call);
  const firstSeenAt = callFirstSeenAtMs.value[callSid];
  const startedAt = callHasActiveRemoteState(call)
    ? firstTimestampMs([
        call?.answeredAt,
        call?.answered_at,
        call?.startedAt,
        call?.started_at,
      ])
    : firstTimestampMs([
        call?.startedAt,
        call?.started_at,
        call?.ringingAt,
        call?.ringing_at,
        call?.createdAt,
        call?.created_at,
      ]);
  const timerStartedAt = startedAt || firstSeenAt;
  if (!timerStartedAt) return idleCallDuration;

  return formatDuration(
    Math.floor((elapsedNowMs.value - timerStartedAt) / 1000)
  );
};

const callDurationLabel = call =>
  callIsActive(call) ? formattedCallDuration.value : remoteCallDuration(call);

const stopElapsedTimer = () => {
  if (!elapsedTimerId) return;

  clearInterval(elapsedTimerId);
  elapsedTimerId = null;
};

const ensureElapsedTimer = () => {
  if (elapsedTimerId || !trackedCallSids.value.length) return;

  elapsedTimerId = setInterval(() => {
    elapsedNowMs.value = Date.now();
  }, 1000);
};

const openConversation = call => {
  if (!call?.conversationId) return;

  const { conversation } = getCallInfo(call);
  const communicationThreadId = getCommunicationThreadId(call, conversation);
  const accountId = router.currentRoute.value.params?.accountId;

  if (communicationThreadId && accountId) {
    const currentParams = router.currentRoute.value.params || {};
    const currentThreadId =
      currentParams.communication_thread_id ||
      currentParams.communicationThreadId;
    if (
      router.currentRoute.value.name === 'communication_thread_conversation' &&
      String(currentThreadId) === String(communicationThreadId)
    ) {
      return;
    }

    router.push({
      name: 'communication_thread_conversation',
      params: {
        accountId,
        communication_thread_id: communicationThreadId,
      },
      query: communicationThreadQuery(),
    });
    return;
  }

  if (
    isCurrentConcreteConversationForCall(call, conversation) ||
    isCurrentCommunicationThreadForCall(call, conversation)
  ) {
    return;
  }

  const inboxId = call.inboxId || conversation?.inbox_id;
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

const handleBrowserJoinUnavailable = ({ notify = true } = {}) => {
  if (notify) {
    useAlert(t('CONVERSATION.VOICE_WIDGET.BROWSER_CALLING_UNAVAILABLE'));
  }
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

const hideCall = call => {
  const callSid = callSidFor(call);
  if (!callSid) return;

  hiddenCallSids.value = new Set([...hiddenCallSids.value, callSid]);
};

const handleCloseCall = call => {
  hideCall(call);
};

const isOwnCall = call =>
  callIsActive(call) || isEmployeeOwnCall(call, currentUserId.value);
// Inside the phone the employee's own calls stay until they end (the phone's
// hide button hides them); info-only cards of other calls can be closed.
const canCloseCall = call => !props.embedded || !isOwnCall(call);

const LETTER_PATTERN = /\p{L}/u;
// The contact's name above the numbers; a name that is only a number (a
// contact created from a dialled number) adds nothing.
const callContactName = call => {
  const { conversation } = getCallInfo(call);
  const name = firstPresent([
    conversation?.meta?.sender?.name,
    call?.caller?.name,
  ]);
  const text = typeof name === 'string' ? name.trim() : '';
  return LETTER_PATTERN.test(text) ? text : '';
};

// Besides the ringtone, the calls that ring here show a system notification
// and blink the tab, so a muted computer does not hide them.
useIncomingCallAttention(
  'voice',
  computed(() =>
    ringingCalls.value.map(call => ({
      key: callSidFor(call),
      body: [
        callContactName(call) || getCallParties(call).customerParty,
        getCallInfo(call).inbox?.name,
      ]
        .filter(Boolean)
        .join(' · '),
    }))
  )
);

const handleJoinCall = async (call, { notifyOnUnavailable = true } = {}) => {
  const { conversation } = getCallInfo(call);
  if (!call || isJoining.value) return;

  if (!browserJoinSupportedForCall(call)) {
    handleBrowserJoinUnavailable({ notify: notifyOnUnavailable });
    return;
  }

  const inboxId = call.inboxId || conversation?.inbox_id;
  if (!inboxId) return;

  if (operatorBusy.value) {
    useAlert(t('CONVERSATION.VOICE_WIDGET.OPERATOR_BUSY'));
    return;
  }

  const result = await joinCall({
    conversationId: call.conversationId,
    inboxId,
    callSid: call.callSid,
    provider: call.provider || getCallInfo(call).provider,
    callDirection: call.callDirection,
    toNumber: call.toNumber,
    sipProfileId: call.sipProfileId || call.sip_profile_id,
    janusCallRef: call.janusCallRef || call.janus_call_ref,
    janusSessionKey: call.janusSessionKey || call.janus_session_key,
  });

  if (result?.joinSupported === false) {
    if (isOutboundCall(call)) return;
    if (result.retryable) return;

    // Another operator won the call (or it ended, or this employee started
    // another one meanwhile): say so in a few words, the card is gone.
    const claimFailureKey = CLAIM_FAILURE_ALERT_KEYS[result.reason];
    if (claimFailureKey) {
      useAlert(t(claimFailureKey));
      return;
    }

    handleBrowserJoinUnavailable({
      notify: notifyOnUnavailable,
    });
  }
};

watch(
  trackedCallSids,
  callSids => {
    const activeCallSids = new Set(callSids);
    const nextHiddenCallSids = new Set(
      [...hiddenCallSids.value].filter(callSid => activeCallSids.has(callSid))
    );
    if (nextHiddenCallSids.size !== hiddenCallSids.value.size) {
      hiddenCallSids.value = nextHiddenCallSids;
    }

    const now = Date.now();
    elapsedNowMs.value = now;
    const nextFirstSeenAtMs = {};
    callSids.forEach(callSid => {
      nextFirstSeenAtMs[callSid] = callFirstSeenAtMs.value[callSid] || now;
    });
    callFirstSeenAtMs.value = nextFirstSeenAtMs;

    if (callSids.length) {
      ensureElapsedTimer();
    } else {
      stopElapsedTimer();
    }
  },
  { immediate: true }
);

const transferPanelOpen = ref(false);
const transferExtension = ref('');
const transferTargets = ref([]);
const isTransferring = ref(false);

const loadTransferTargets = async call => {
  const accountId = router.currentRoute.value.params?.accountId;
  const inboxId = call?.inboxId || getCallInfo(call).conversation?.inbox_id;
  if (!accountId) return;
  try {
    const response = await window.axios.get(
      `/api/v1/accounts/${accountId}/telephony/webphone/channel_capacity`,
      { params: inboxId ? { inbox_id: inboxId } : {} }
    );
    transferTargets.value = response?.data?.transfer_targets || [];
    if (!transferExtension.value && transferTargets.value.length) {
      transferExtension.value = transferTargets.value[0].internal_extension;
    }
  } catch {
    transferTargets.value = [];
  }
};

const toggleTransferPanel = call => {
  transferPanelOpen.value = !transferPanelOpen.value;
  if (transferPanelOpen.value) {
    loadTransferTargets(call);
  }
};

const submitCallTransfer = async call => {
  const ext = transferExtension.value.trim();
  const accountId = router.currentRoute.value.params?.accountId;
  if (!ext || !accountId || isTransferring.value) return;

  isTransferring.value = true;
  try {
    const inboxId = call?.inboxId || getCallInfo(call).conversation?.inbox_id;
    const customerNumber = getCallParties(call).customerParty;
    await window.axios.post(
      `/api/v1/accounts/${accountId}/telephony/webphone/transfer`,
      {
        inbox_id: inboxId,
        target_extension: ext,
        customer_number: customerNumber,
        flow: 'blind',
      }
    );
    transferPanelOpen.value = false;
    useAlert(`Звонок переведён на номер ${ext}`);
  } catch {
    useAlert('Не удалось перевести звонок');
  } finally {
    isTransferring.value = false;
  }
};

const CALL_CARD_EXPANDED_STORAGE_KEY = 'chatwoot_call_card_expanded';
const readInitialCallCardExpanded = () => {
  try {
    const raw = window.localStorage?.getItem(CALL_CARD_EXPANDED_STORAGE_KEY);
    if (raw === 'false') return false;
    if (raw === 'true') return true;
  } catch {
    // Ignore storage read errors
  }
  return null;
};

const callCardExpandedOverride = ref(readInitialCallCardExpanded());

const isCallCardExpandedFor = call => {
  if (callCardExpandedOverride.value !== null) {
    return callCardExpandedOverride.value;
  }
  const { inbox } = getCallInfo(call);
  const channelDefault =
    inbox?.call_routing?.show_extended_call_card ??
    inbox?.provider_config?.call_routing?.show_extended_call_card ??
    inbox?.telephony?.routing_policy?.settings?.call_routing
      ?.show_extended_call_card ??
    inbox?.additional_attributes?.call_routing?.show_extended_call_card ??
    inbox?.additional_attributes?.show_extended_call_card;
  if (typeof channelDefault === 'boolean') {
    return channelDefault;
  }
  return true;
};

const toggleCallCardExpanded = call => {
  const nextValue = !isCallCardExpandedFor(call);
  callCardExpandedOverride.value = nextValue;
  try {
    window.localStorage?.setItem(
      CALL_CARD_EXPANDED_STORAGE_KEY,
      String(nextValue)
    );
  } catch {
    // Ignore storage write errors
  }
};

const getCallClientContext = call => {
  if (!isCallCardExpandedFor(call)) {
    return null;
  }

  const { conversation } = getCallInfo(call);
  const contactId = getCallContactId(call, conversation);
  const storeContact =
    (contactId && store.getters['contacts/getContact']?.(contactId)) || {};
  const sender = conversation?.meta?.sender || {};
  const caller = call?.caller || {};

  const company = firstPresent([
    storeContact?.additional_attributes?.company_name,
    storeContact?.additionalAttributes?.companyName,
    storeContact?.custom_attributes?.company,
    storeContact?.custom_attributes?.company_name,
    sender?.additional_attributes?.company_name,
    sender?.custom_attributes?.company,
    caller?.company_name,
    conversation?.additional_attributes?.company_name,
    conversation?.custom_attributes?.company,
  ]);

  const assigneeName = firstPresent([
    conversation?.meta?.assignee?.name,
    conversation?.assignee?.name,
  ]);

  const dealStages = Array.isArray(conversation?.crm_deal_stages)
    ? conversation.crm_deal_stages
        .map(stage => stage?.name || stage?.title)
        .filter(Boolean)
    : [];
  const customDealTitle = firstPresent([
    conversation?.custom_attributes?.deal_name,
    conversation?.custom_attributes?.deal_title,
    conversation?.custom_attributes?.deal_stage,
    conversation?.custom_attributes?.subject,
    conversation?.additional_attributes?.deal_title,
  ]);
  const dealSummary = [customDealTitle, ...dealStages]
    .filter(Boolean)
    .join(' · ');

  const scheduledEvent = firstPresent([
    conversation?.custom_attributes?.next_event,
    conversation?.custom_attributes?.scheduled_event,
    conversation?.additional_attributes?.next_event,
    storeContact?.custom_attributes?.next_event,
  ]);

  const labels = Array.isArray(conversation?.labels)
    ? conversation.labels.filter(Boolean).slice(0, 4)
    : [];

  const privateMessages = Array.isArray(conversation?.messages)
    ? conversation.messages.filter(msg => msg?.private && msg?.content)
    : [];
  const latestPrivateMessage = privateMessages[privateMessages.length - 1];
  const latestNote = firstPresent([
    latestPrivateMessage?.content,
    conversation?.custom_attributes?.call_note,
    storeContact?.custom_attributes?.notes,
  ]);

  const hasAnyDetail = Boolean(
    company ||
      assigneeName ||
      dealSummary ||
      scheduledEvent ||
      labels.length ||
      latestNote
  );

  return {
    company,
    assigneeName,
    dealSummary,
    scheduledEvent,
    labels,
    latestNote,
    hasAnyDetail,
  };
};

const quickNoteOpenCallSid = ref('');
const quickNoteDraft = ref('');
const isSavingQuickNote = ref(false);

const toggleQuickNote = call => {
  const sid = callSidFor(call);
  if (quickNoteOpenCallSid.value === sid) {
    quickNoteOpenCallSid.value = '';
    return;
  }
  quickNoteOpenCallSid.value = sid;
  quickNoteDraft.value = '';
};

const submitQuickNote = async call => {
  const content = quickNoteDraft.value.trim();
  const accountId = router.currentRoute.value.params?.accountId;
  const conversationId = call?.conversationId;
  if (!content || !accountId || !conversationId || isSavingQuickNote.value) {
    return;
  }

  isSavingQuickNote.value = true;
  try {
    await window.axios.post(
      `/api/v1/accounts/${accountId}/conversations/${conversationId}/messages`,
      {
        content,
        private: true,
      }
    );
    quickNoteDraft.value = '';
    quickNoteOpenCallSid.value = '';
    useAlert('Заметка сохранена в карточке обращения');
  } catch {
    useAlert('Не удалось сохранить заметку');
  } finally {
    isSavingQuickNote.value = false;
  }
};

onUnmounted(stopElapsedTimer);
</script>

<template>
  <div class="contents">
    <template v-if="visibleCalls.length">
      <div
        :class="
          props.embedded
            ? 'flex flex-col divide-y divide-n-weak border-b border-n-weak'
            : 'fixed ltr:right-4 rtl:left-4 bottom-4 z-50 flex flex-col gap-2 w-[320px] sm:w-[340px] max-w-[calc(100vw-2rem)]'
        "
        :data-testid="props.embedded ? 'phone-widget-calls' : 'floating-calls'"
      >
        <div
          v-for="call in visibleCalls"
          :key="call.callSid"
          class="relative flex gap-2"
          :class="[
            props.embedded
              ? 'px-4 py-3'
              : 'p-2.5 bg-n-solid-2 rounded-lg shadow-xl outline outline-1 outline-n-strong',
            { 'ltr:pr-10 rtl:pl-10': canCloseCall(call) },
          ]"
          :data-testid="props.embedded ? 'phone-widget-call-card' : undefined"
          :data-own-call="props.embedded ? String(isOwnCall(call)) : undefined"
        >
          <button
            v-if="canCloseCall(call)"
            type="button"
            class="absolute top-2 ltr:right-2 rtl:left-2 inline-flex size-7 p-0 justify-center items-center text-n-slate-10 hover:text-n-slate-12 hover:bg-n-alpha-2 rounded-md transition-colors"
            :title="$t('CONVERSATION.VOICE_WIDGET.CLOSE')"
            :aria-label="$t('CONVERSATION.VOICE_WIDGET.CLOSE')"
            @click="handleCloseCall(call)"
          >
            <i class="text-base i-lucide-x" />
          </button>
          <div class="flex flex-col items-center w-11 shrink-0 gap-1">
            <span
              class="inline-flex rounded-full"
              :class="{
                'ring-2 ring-n-teal-9': callIsLiveActive(call),
                'animate-pulse ring-2 ring-n-teal-9':
                  !callIsLiveActive(call) &&
                  isIncomingCallActionableInBrowser(call),
              }"
            >
              <Avatar
                :src="getCallInfo(call).avatar"
                :name="getCallInfo(call).contactName"
                :size="36"
                rounded-full
              />
            </span>
            <span
              class="font-mono leading-4 tabular-nums text-xs"
              :class="
                callIsLiveActive(call)
                  ? 'font-medium text-n-teal-9'
                  : 'font-normal text-n-slate-11'
              "
            >
              {{ callDurationLabel(call) }}
            </span>
          </div>
          <div class="flex-1 min-w-0">
            <p
              v-if="props.embedded && callContactName(call)"
              class="mb-0.5 truncate text-sm font-semibold text-n-slate-12"
              data-testid="phone-widget-call-name"
            >
              {{ callContactName(call) }}
            </p>
            <div class="relative flex items-start gap-1.5 min-w-0">
              <i
                class="mt-0.5 text-[14px] shrink-0"
                :class="[
                  channelIconClass(call),
                  isWhatsappCall(call) ? 'text-n-teal-9' : 'channel-icon-voice',
                ]"
              />
              <p
                class="min-w-0 flex flex-1 items-center text-sm font-medium mb-0"
                :title="`${getCallRouteParts(call).from} ${$t('CONVERSATION.VOICE_WIDGET.ROUTE_SEPARATOR')} ${getCallRouteParts(call).to}`"
              >
                <span class="min-w-0 truncate">
                  {{ getCallRouteParts(call).from }}
                </span>
                <span
                  class="mx-0.5 shrink-0 text-[10px] font-normal text-n-slate-11"
                >
                  {{ $t('CONVERSATION.VOICE_WIDGET.ROUTE_SEPARATOR') }}
                </span>
                <span class="min-w-0 truncate">
                  {{ getCallRouteParts(call).to }}
                </span>
              </p>
            </div>

            <div class="flex items-center justify-between gap-1 mt-0.5">
              <p class="text-xs text-n-slate-11 truncate mb-0">
                {{ getCallSecondaryText(call) }}
              </p>
              <button
                type="button"
                class="shrink-0 inline-flex items-center gap-0.5 rounded px-1.5 py-0.5 text-[11px] font-medium text-n-slate-11 hover:bg-n-alpha-2 hover:text-n-slate-12 transition-colors"
                :title="
                  isCallCardExpandedFor(call)
                    ? 'Переключить в компактный вид'
                    : 'Переключить в подробный вид'
                "
                data-testid="floating-call-context-toggle"
                @click="toggleCallCardExpanded(call)"
              >
                <span>
                  {{
                    isCallCardExpandedFor(call)
                      ? 'Компактный вид'
                      : 'Подробный вид'
                  }}
                </span>
                <i
                  class="text-xs"
                  :class="
                    isCallCardExpandedFor(call)
                      ? 'i-lucide-chevron-up'
                      : 'i-lucide-chevron-down'
                  "
                />
              </button>
            </div>

            <div
              v-if="
                isCallCardExpandedFor(call) &&
                getCallClientContext(call)?.hasAnyDetail
              "
              class="mt-1.5 rounded-md bg-n-alpha-1 px-2 py-1.5 text-xs flex flex-col gap-1 border border-n-weak"
              data-testid="floating-call-client-context"
            >
              <div
                v-if="getCallClientContext(call).company"
                class="flex items-center gap-1.5 min-w-0"
                data-testid="floating-call-context-company"
              >
                <span class="text-n-slate-11 shrink-0">Компания:</span>
                <span class="font-medium text-n-slate-12 truncate">
                  {{ getCallClientContext(call).company }}
                </span>
              </div>
              <div
                v-if="getCallClientContext(call).assigneeName"
                class="flex items-center gap-1.5 min-w-0"
                data-testid="floating-call-context-manager"
              >
                <span class="text-n-slate-11 shrink-0">
                  Ответственный менеджер:
                </span>
                <span class="font-medium text-n-slate-12 truncate">
                  {{ getCallClientContext(call).assigneeName }}
                </span>
              </div>
              <div
                v-if="getCallClientContext(call).dealSummary"
                class="flex items-center gap-1.5 min-w-0"
                data-testid="floating-call-context-deal"
              >
                <span class="text-n-slate-11 shrink-0">
                  Текущее обращение / Сделка:
                </span>
                <span class="font-medium text-n-slate-12 truncate">
                  {{ getCallClientContext(call).dealSummary }}
                </span>
              </div>
              <div
                v-if="getCallClientContext(call).scheduledEvent"
                class="flex items-center gap-1.5 min-w-0"
                data-testid="floating-call-context-event"
              >
                <span class="text-n-slate-11 shrink-0">
                  Запланированное событие:
                </span>
                <span class="font-medium text-n-slate-12 truncate">
                  {{ getCallClientContext(call).scheduledEvent }}
                </span>
              </div>
              <div
                v-if="getCallClientContext(call).labels.length"
                class="flex flex-wrap items-center gap-1"
                data-testid="floating-call-context-labels"
              >
                <span
                  v-for="label in getCallClientContext(call).labels"
                  :key="label"
                  class="inline-flex items-center rounded bg-n-alpha-2 px-1.5 py-0.5 text-[10px] font-medium text-n-slate-12"
                >
                  #{{ label }}
                </span>
              </div>
              <div
                v-if="getCallClientContext(call).latestNote"
                class="text-[11px] text-n-slate-11 truncate"
                data-testid="floating-call-context-note"
              >
                <span class="font-medium text-n-slate-12">Заметка:</span>
                {{ getCallClientContext(call).latestNote }}
              </div>
            </div>

            <p
              v-if="callMicrophoneOff(call)"
              class="mt-1 mb-0 inline-flex items-center gap-1 rounded-md bg-n-ruby-9 px-1.5 py-0.5 text-xs font-medium text-white"
              data-testid="call-microphone-off"
            >
              <i class="i-lucide-mic-off text-sm" aria-hidden="true" />
              {{ t('PHONE_WIDGET.MICROPHONE_OFF') }}
            </p>

            <p
              v-if="showBusyNote(call)"
              class="mt-1 mb-0 text-xs text-n-slate-11"
              data-testid="call-busy-note"
            >
              {{ t('CONVERSATION.VOICE_WIDGET.BUSY_ON_CALL') }}
            </p>

            <div class="flex items-center gap-2 mt-2">
              <!-- Muted: a filled red pressed button with its own label. -->
              <button
                v-if="
                  !props.embedded && callIsActive(call) && !isWhatsappCall(call)
                "
                type="button"
                class="inline-flex items-center justify-center w-10 h-10 rounded-full transition-colors disabled:opacity-50"
                :class="
                  microphoneMuted
                    ? 'bg-n-ruby-9 text-white hover:bg-n-ruby-10 shadow-sm'
                    : 'bg-n-alpha-2 text-n-slate-12 hover:bg-n-alpha-1'
                "
                :disabled="!microphoneAvailable"
                :title="microphoneLabel"
                :aria-label="microphoneLabel"
                :aria-pressed="microphoneMuted"
                data-testid="floating-call-microphone"
                @click="toggleMicrophone"
              >
                <i
                  class="text-base"
                  :class="microphoneMuted ? 'i-lucide-mic-off' : 'i-lucide-mic'"
                />
              </button>
              <button
                v-if="callIsActive(call)"
                type="button"
                class="inline-flex items-center justify-center w-10 h-10 rounded-full transition-colors bg-n-ruby-9 text-white hover:bg-n-ruby-10 shadow-sm"
                :title="$t('CONVERSATION.VOICE_WIDGET.END_CALL')"
                :aria-label="$t('CONVERSATION.VOICE_WIDGET.END_CALL')"
                @click="handleEndCall"
              >
                <i class="text-base i-ph-phone-x-bold" />
              </button>
              <button
                v-if="
                  !callIsLiveActive(call) &&
                  !isOutboundCall(call) &&
                  browserJoinSupportedForCall(call) &&
                  isIncomingCallActionableInBrowser(call)
                "
                type="button"
                class="inline-flex items-center justify-center w-10 h-10 rounded-full transition-colors bg-n-teal-9 text-white hover:bg-n-teal-10 shadow-sm"
                :title="$t('CONVERSATION.VOICE_WIDGET.CALL')"
                :aria-label="$t('CONVERSATION.VOICE_WIDGET.CALL')"
                :disabled="operatorBusy || isJoining"
                @click="handleJoinCall(call)"
              >
                <i class="text-base i-ph-phone-bold" />
              </button>
              <button
                v-if="
                  !callIsLiveActive(call) &&
                  (isOutboundCall(call) ||
                    isIncomingCallActionableInBrowser(call))
                "
                type="button"
                class="inline-flex items-center justify-center w-10 h-10 rounded-full transition-colors bg-n-ruby-9 text-white hover:bg-n-ruby-10 shadow-sm"
                :title="callCancelLabel(call)"
                :aria-label="callCancelLabel(call)"
                @click="rejectIncomingCall(call)"
              >
                <i class="text-base i-ph-phone-x-bold" />
              </button>
              <button
                v-if="callIsActive(call) && !isWhatsappCall(call)"
                type="button"
                class="inline-flex items-center justify-center w-10 h-10 rounded-full transition-colors"
                :class="
                  transferPanelOpen
                    ? 'bg-n-brand text-white shadow-sm'
                    : 'bg-n-alpha-2 text-n-slate-12 hover:bg-n-alpha-1'
                "
                title="Перевести звонок"
                aria-label="Перевести звонок"
                data-testid="floating-call-transfer"
                @click="toggleTransferPanel(call)"
              >
                <i class="text-base i-lucide-phone-forwarded" />
              </button>
              <button
                v-if="call.conversationId"
                type="button"
                class="inline-flex items-center justify-center w-10 h-10 rounded-full transition-colors"
                :class="
                  quickNoteOpenCallSid === callSidFor(call)
                    ? 'bg-n-brand text-white shadow-sm'
                    : 'bg-n-alpha-2 text-n-slate-12 hover:bg-n-alpha-1'
                "
                title="Быстрая заметка по звонку"
                aria-label="Быстрая заметка по звонку"
                data-testid="floating-call-quick-note-toggle"
                @click="toggleQuickNote(call)"
              >
                <i class="text-base i-lucide-sticky-note" />
              </button>
              <button
                type="button"
                class="inline-flex items-center justify-center w-10 h-10 rounded-full transition-colors bg-n-alpha-2 text-n-slate-12 hover:bg-n-alpha-1"
                :title="$t('CONVERSATION.VOICE_WIDGET.OPEN_CHAT')"
                :aria-label="$t('CONVERSATION.VOICE_WIDGET.OPEN_CHAT')"
                @click="openConversation(call)"
              >
                <i class="text-base i-ph-chat-circle-bold" />
              </button>
            </div>
            <div
              v-if="
                quickNoteOpenCallSid === callSidFor(call) && call.conversationId
              "
              class="mt-2 flex items-center gap-1.5 rounded-md bg-n-alpha-1 p-1.5"
              data-testid="floating-call-quick-note-panel"
            >
              <input
                v-model="quickNoteDraft"
                type="text"
                placeholder="Быстрая заметка по звонку..."
                class="min-w-0 flex-1 rounded border border-n-weak bg-n-solid-1 px-2 py-1 text-xs text-n-slate-12"
                data-testid="floating-call-quick-note-input"
                @keyup.enter="submitQuickNote(call)"
              />
              <button
                type="button"
                class="shrink-0 rounded bg-n-brand px-2.5 py-1 text-xs font-medium text-white hover:opacity-90 disabled:opacity-50"
                :disabled="!quickNoteDraft.trim() || isSavingQuickNote"
                data-testid="floating-call-quick-note-submit"
                @click="submitQuickNote(call)"
              >
                Сохранить
              </button>
            </div>
            <div
              v-if="
                transferPanelOpen &&
                callIsActive(call) &&
                !isWhatsappCall(call)
              "
              class="mt-2 flex items-center gap-1.5 rounded-md bg-n-alpha-1 p-1.5"
              data-testid="floating-call-transfer-panel"
            >
              <select
                v-if="transferTargets.length"
                v-model="transferExtension"
                class="min-w-0 flex-1 rounded border border-n-weak bg-n-solid-1 px-2 py-1 text-xs text-n-slate-12"
                data-testid="floating-call-transfer-select"
              >
                <option
                  v-for="target in transferTargets"
                  :key="target.internal_extension"
                  :value="target.internal_extension"
                >
                  {{ target.name }} ({{ target.internal_extension }})
                </option>
                <option value="2001">Общая группа (2001)</option>
              </select>
              <input
                v-else
                v-model="transferExtension"
                type="text"
                placeholder="Внутр. номер (напр. 1002 / 2001)"
                class="min-w-0 flex-1 rounded border border-n-weak bg-n-solid-1 px-2 py-1 text-xs text-n-slate-12"
                data-testid="floating-call-transfer-input"
              />
              <button
                type="button"
                class="shrink-0 rounded bg-n-teal-9 px-2.5 py-1 text-xs font-medium text-white hover:bg-n-teal-10 disabled:opacity-50"
                :disabled="!transferExtension.trim() || isTransferring"
                data-testid="floating-call-transfer-submit"
                @click="submitCallTransfer(call)"
              >
                Перевести
              </button>
            </div>
          </div>
        </div>
      </div>
    </template>
  </div>
</template>
