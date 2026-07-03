import { defineStore } from 'pinia';
import { TERMINAL_STATUSES } from 'dashboard/helper/voice';

const isPresent = value =>
  value !== undefined && value !== null && value !== '';

const sameValue = (left, right) =>
  isPresent(left) && isPresent(right) && String(left) === String(right);

const sameCallSid = (call, callSid) => sameValue(call?.callSid, callSid);

const callLogicalKey = call =>
  call?.logicalCallKey ||
  call?.logical_call_key ||
  call?.callGroupKey ||
  call?.call_group_key;

const hasLogicalCallKey = call => isPresent(callLogicalKey(call));

const scopedCallKeys = entries =>
  entries.flatMap(([scope, ...values]) =>
    values.filter(isPresent).map(value => `${scope}:${String(value)}`)
  );

const callConversationKeys = call =>
  scopedCallKeys([
    [
      'conversation',
      call?.conversationId,
      call?.conversationDisplayId,
      call?.conversation_id,
      call?.conversation_display_id,
    ],
    [
      'communication_thread',
      call?.communicationThreadId,
      call?.communication_thread_id,
    ],
    ['conversation_db', call?.conversationDbId, call?.conversation_db_id],
  ]);

const hasSharedConversationKey = (call, callData) => {
  const callKeys = callConversationKeys(call);
  const callDataKeys = callConversationKeys(callData);
  return callKeys.some(key => callDataKeys.includes(key));
};

const relatedCallSids = callData =>
  [
    callData?.callSid,
    callData?.call_sid,
    callData?.call_ref,
    ...(callData?.relatedCallSids || []),
    ...(callData?.related_call_sids || []),
  ]
    .filter(isPresent)
    .map(value => String(value));

const NATIVE_BROWSER_SIP_PROVIDERS = new Set([
  'fonoster',
  'asterisk_analog',
  'sipuni',
  'binotel',
]);
const TERMINAL_CALL_SUPPRESSION_MS = 5 * 60 * 1000;

const isNativeBrowserSipCall = call =>
  NATIVE_BROWSER_SIP_PROVIDERS.has(call?.provider);

const isInboundCall = call => {
  const direction = call?.callDirection || call?.direction;
  return direction === 'inbound';
};

const sameFonosterConversation = (
  call,
  callData,
  { allowCallSidMismatch = false } = {}
) => {
  if (
    !isNativeBrowserSipCall(call) ||
    !isNativeBrowserSipCall(callData) ||
    call?.provider !== callData?.provider
  ) {
    return false;
  }

  if (
    !allowCallSidMismatch &&
    isPresent(call?.callSid) &&
    isPresent(callData?.callSid)
  ) {
    return false;
  }

  if (
    (isInboundCall(call) || isInboundCall(callData)) &&
    (hasLogicalCallKey(call) || hasLogicalCallKey(callData))
  ) {
    return false;
  }

  return hasSharedConversationKey(call, callData);
};

const sameFonosterInboundBranch = (call, callData) => {
  if (!isNativeBrowserSipCall(call) || !isNativeBrowserSipCall(callData)) {
    return false;
  }
  if (call?.provider !== callData?.provider) return false;
  if (!isInboundCall(call) || !isInboundCall(callData)) return false;

  return sameValue(callLogicalKey(call), callLogicalKey(callData));
};

const sameFonosterInboundConversation = (call, callData) => {
  if (!isNativeBrowserSipCall(call) || !isNativeBrowserSipCall(callData)) {
    return false;
  }
  if (call?.provider !== callData?.provider) return false;
  if (!isInboundCall(call) || !isInboundCall(callData)) return false;
  if (hasLogicalCallKey(call) || hasLogicalCallKey(callData)) return false;

  return hasSharedConversationKey(call, callData);
};

const sameLiveCall = (call, callData) =>
  sameCallSid(call, callData?.callSid) ||
  sameFonosterInboundBranch(call, callData) ||
  sameFonosterConversation(call, callData, { allowCallSidMismatch: true });

const terminalSuppressionKeys = call => {
  const provider = call?.provider;
  const callSid = call?.callSid || call?.call_sid || call?.call_ref;
  const logicalKey = callLogicalKey(call);
  return [
    isPresent(callSid) ? `sid:${callSid}` : null,
    isPresent(callSid) && isPresent(provider)
      ? `sid:${provider}:${callSid}`
      : null,
    isPresent(logicalKey) ? `logical:${logicalKey}` : null,
    isPresent(logicalKey) && isPresent(provider)
      ? `logical:${provider}:${logicalKey}`
      : null,
  ].filter(Boolean);
};

const nonTerminalCallStatus = status => !TERMINAL_STATUSES.includes(status);

const isRelatedFonosterInbound = (call, targetCall) =>
  sameFonosterInboundBranch(call, targetCall) ||
  sameFonosterInboundConversation(call, targetCall);

const visibleIncomingCalls = calls => {
  const activeCall = calls.find(call => call.isActive);
  return calls.filter(call => {
    if (call.isActive) return false;
    if (!activeCall) return true;

    return !sameFonosterInboundConversation(call, activeCall);
  });
};

const hasOwn = (object, key) =>
  Object.prototype.hasOwnProperty.call(object || {}, key);

const buildCallState = (callData, existingCall = null) => {
  const isSameProviderCall = sameCallSid(existingCall, callData?.callSid);
  const preserveExistingCallSid =
    existingCall &&
    !isSameProviderCall &&
    sameFonosterInboundBranch(existingCall, callData);
  const hasStatusUpdate = hasOwn(callData, 'status');
  const stageValue = key => {
    if (hasOwn(callData, key)) return callData[key] ?? null;
    return hasStatusUpdate ? null : (existingCall?.[key] ?? null);
  };
  const displayValue = key => {
    if (isPresent(callData?.[key])) return callData[key];
    return existingCall?.[key] ?? null;
  };

  return {
    ...(existingCall || {}),
    ...(callData || {}),
    status: hasStatusUpdate
      ? (callData?.status ?? null)
      : (existingCall?.status ?? null),
    callSid: preserveExistingCallSid
      ? existingCall.callSid
      : (callData?.callSid ?? existingCall?.callSid),
    callEvent: stageValue('callEvent'),
    callLeg: stageValue('callLeg'),
    rawStatus: stageValue('rawStatus'),
    startedAt: displayValue('startedAt'),
    answeredAt: displayValue('answeredAt'),
    accountId: displayValue('accountId'),
    conversationDbId: displayValue('conversationDbId'),
    conversationDisplayId: displayValue('conversationDisplayId'),
    communicationThreadId: displayValue('communicationThreadId'),
    contactId: displayValue('contactId'),
    logicalCallKey: displayValue('logicalCallKey'),
    numberRef: displayValue('numberRef'),
    fromNumber: displayValue('fromNumber'),
    toNumber: displayValue('toNumber'),
    caller: displayValue('caller'),
    operatorClaim: displayValue('operatorClaim'),
    operatorCandidates: displayValue('operatorCandidates'),
    operatorInternalExtension: displayValue('operatorInternalExtension'),
    sipProfileId: displayValue('sipProfileId'),
    janusCallRef: displayValue('janusCallRef'),
    janusSessionKey: displayValue('janusSessionKey'),
    sipuniNativeWebphoneCorrelation: displayValue(
      'sipuniNativeWebphoneCorrelation'
    ),
    browserJoinUnsupportedReason: displayValue('browserJoinUnsupportedReason'),
    isActive: isSameProviderCall ? existingCall?.isActive || false : false,
    browserJoined: isSameProviderCall
      ? existingCall?.browserJoined || false
      : false,
    browserJoinSupported:
      callData?.browserJoinSupported ??
      (isSameProviderCall ? existingCall?.browserJoinSupported : null) ??
      null,
  };
};

const loadWebphoneClient = async () => {
  const { default: WebphoneClient } = await import(
    'dashboard/api/channel/voice/webphoneClient'
  );
  return WebphoneClient;
};

const endClientCall = async callOrProvider => {
  try {
    const WebphoneClient = await loadWebphoneClient();
    await WebphoneClient.endClientCall(callOrProvider);
  } catch {
    // Browser-side cleanup is best effort; call state is already removed.
  }
};

export const useCallsStore = defineStore('calls', {
  state: () => ({
    calls: [],
    terminalCallKeys: {},
  }),

  getters: {
    activeCall: state => state.calls.find(call => call.isActive) || null,
    hasActiveCall: state => state.calls.some(call => call.isActive),
    incomingCalls: state => visibleIncomingCalls(state.calls),
    hasIncomingCall: state => visibleIncomingCalls(state.calls).length > 0,
  },

  actions: {
    handleCallStatusChanged({
      callSid,
      status,
      conversationId,
      inboxId,
      provider,
      callDirection,
      senderId,
      callEvent,
      callLeg,
      rawStatus,
      startedAt,
      answeredAt,
      fromNumber,
      toNumber,
      caller,
      operatorClaim,
      operatorCandidates,
      operatorInternalExtension,
      sipProfileId,
      janusCallRef,
      janusSessionKey,
      sipuniNativeWebphoneCorrelation,
      browserJoinSupported,
      accountId,
      conversationDbId,
      conversationDisplayId,
      communicationThreadId,
      contactId,
      logicalCallKey,
      numberRef,
    }) {
      const callData = {
        callSid,
        accountId,
        conversationId,
        conversationDbId,
        conversationDisplayId,
        communicationThreadId,
        inboxId,
        provider,
        callDirection,
        senderId,
        contactId,
        logicalCallKey,
        numberRef,
        fromNumber,
        toNumber,
        startedAt,
        answeredAt,
        sipProfileId,
        janusCallRef,
        janusSessionKey,
        sipuniNativeWebphoneCorrelation,
        browserJoinSupported,
      };

      if (TERMINAL_STATUSES.includes(status)) {
        this.rememberTerminalCall(callData);
        this.removeCall(callSid, {
          conversationId,
          provider,
          callDirection,
          logicalCallKey,
        });
        return;
      }

      if (this.isRecentlyTerminalCall(callData)) return;

      const call = this.calls.find(
        item => sameCallSid(item, callSid) || sameLiveCall(item, callData)
      );
      const resolvedProvider = call?.provider || provider;
      const resolvedCallDirection = call?.callDirection || callDirection;

      if (call) {
        this.addCall({
          callSid: call?.callSid || callSid,
          status,
          accountId,
          conversationId,
          conversationDbId,
          conversationDisplayId,
          communicationThreadId,
          inboxId,
          provider: resolvedProvider,
          callDirection: resolvedCallDirection,
          senderId,
          contactId,
          logicalCallKey,
          numberRef,
          callEvent,
          callLeg,
          rawStatus,
          fromNumber,
          toNumber,
          startedAt,
          answeredAt,
          caller,
          operatorClaim,
          operatorCandidates,
          operatorInternalExtension,
          sipProfileId,
          janusCallRef,
          janusSessionKey,
          sipuniNativeWebphoneCorrelation,
          browserJoinSupported,
        });
      }

      if (status === 'in_progress') {
        if (
          NATIVE_BROWSER_SIP_PROVIDERS.has(resolvedProvider) &&
          resolvedCallDirection === 'outbound'
        ) {
          if (!call) {
            this.addCall({
              callSid,
              status,
              accountId,
              conversationId,
              conversationDbId,
              conversationDisplayId,
              communicationThreadId,
              inboxId,
              provider: resolvedProvider,
              callDirection: resolvedCallDirection,
              senderId,
              contactId,
              logicalCallKey,
              numberRef,
              callEvent,
              callLeg,
              rawStatus,
              startedAt,
              answeredAt,
              fromNumber,
              toNumber,
              caller,
              operatorClaim,
              operatorCandidates,
              operatorInternalExtension,
              sipProfileId,
              janusCallRef,
              janusSessionKey,
              sipuniNativeWebphoneCorrelation,
              browserJoinSupported,
            });
          }
          this.setCallActive(call?.callSid || callSid);
          return;
        }
        this.addCall({
          callSid: call?.callSid || callSid,
          status,
          accountId,
          conversationId,
          conversationDbId,
          conversationDisplayId,
          communicationThreadId,
          inboxId,
          provider: resolvedProvider,
          callDirection: resolvedCallDirection || 'inbound',
          senderId,
          contactId,
          logicalCallKey,
          numberRef,
          callEvent,
          callLeg,
          rawStatus,
          startedAt,
          answeredAt,
          fromNumber,
          toNumber,
          caller,
          operatorClaim,
          operatorCandidates,
          operatorInternalExtension,
          sipProfileId,
          janusCallRef,
          janusSessionKey,
          sipuniNativeWebphoneCorrelation,
          browserJoinSupported: call?.isActive ? browserJoinSupported : false,
          browserJoinUnsupportedReason: call?.isActive
            ? call?.browserJoinUnsupportedReason
            : 'CALL_IN_PROGRESS',
        });
      }
    },

    addCall(callData) {
      if (!callData?.callSid) return;
      if (
        nonTerminalCallStatus(callData?.status) &&
        this.isRecentlyTerminalCall(callData)
      ) {
        return;
      }

      const existingCallIndex = this.calls.findIndex(call =>
        sameLiveCall(call, callData)
      );

      if (existingCallIndex >= 0) {
        const existingCall = this.calls[existingCallIndex];
        if (
          existingCall?.isActive &&
          !sameCallSid(existingCall, callData.callSid) &&
          isRelatedFonosterInbound(existingCall, callData)
        ) {
          this.dismissRelatedFonosterIncomingCalls(existingCall);
          return;
        }
        const replacedActiveCall =
          existingCall?.isActive &&
          !sameCallSid(existingCall, callData.callSid);
        const mergedCall = buildCallState(callData, existingCall);
        this.calls = this.calls.reduce((calls, call, index) => {
          if (index === existingCallIndex) {
            calls.push(mergedCall);
            return calls;
          }

          if (!sameLiveCall(call, mergedCall)) calls.push(call);
          return calls;
        }, []);
        if (replacedActiveCall) endClientCall(existingCall);
        return;
      }

      const activeCall = this.calls.find(call => call.isActive);
      if (activeCall && isRelatedFonosterInbound(activeCall, callData)) {
        this.dismissRelatedFonosterIncomingCalls(activeCall);
        return;
      }

      this.calls.push(buildCallState(callData));
    },

    pruneTerminalCallKeys() {
      const now = Date.now();
      this.terminalCallKeys = Object.entries(this.terminalCallKeys).reduce(
        (keys, [key, expiresAt]) => {
          if (expiresAt > now) keys[key] = expiresAt;
          return keys;
        },
        {}
      );
    },

    rememberTerminalCall(callData) {
      const keys = terminalSuppressionKeys(callData);
      if (!keys.length) return;

      this.pruneTerminalCallKeys();
      const expiresAt = Date.now() + TERMINAL_CALL_SUPPRESSION_MS;
      keys.forEach(key => {
        this.terminalCallKeys[key] = expiresAt;
      });
    },

    isRecentlyTerminalCall(callData) {
      const keys = terminalSuppressionKeys(callData);
      if (!keys.length) return false;

      this.pruneTerminalCallKeys();
      const now = Date.now();
      return keys.some(key => (this.terminalCallKeys[key] || 0) > now);
    },

    markBrowserJoinUnsupported(callSid, provider, details = {}) {
      this.calls = this.calls.map(call =>
        call.callSid === callSid
          ? {
              ...call,
              browserJoinSupported: false,
              browserJoinUnsupportedReason:
                details.reason || call.browserJoinUnsupportedReason,
              operatorClaim:
                details.operatorClaim || call.operatorClaim || null,
              provider: provider || call.provider,
            }
          : call
      );
    },

    markBrowserJoined(callSid, provider) {
      this.calls = this.calls.map(call =>
        call.callSid === callSid
          ? {
              ...call,
              browserJoined: true,
              provider: provider || call.provider,
            }
          : call
      );
    },

    async removeCall(
      callSid,
      { conversationId, provider, callDirection, logicalCallKey } = {}
    ) {
      const target = {
        callSid,
        conversationId,
        provider,
        callDirection,
        logicalCallKey,
      };
      const matchesLogicalBranch = call =>
        sameFonosterInboundBranch(call, target) &&
        (!call.isActive || !isPresent(target.callSid));
      const matchesTarget = call =>
        sameCallSid(call, target.callSid) ||
        matchesLogicalBranch(call) ||
        sameFonosterConversation(call, target);
      const callToRemove = this.calls.find(matchesTarget);
      this.calls = this.calls.filter(c => !matchesTarget(c));

      if (callToRemove?.isActive) {
        await endClientCall(callToRemove);
      }
    },

    setCallActive(callSid) {
      const activeCall = this.calls.find(call => call.callSid === callSid);
      this.calls = this.calls.map(call => ({
        ...call,
        isActive: call.callSid === callSid,
      }));
      if (activeCall && sameFonosterInboundBranch(activeCall, activeCall)) {
        this.dismissRelatedFonosterIncomingCalls(activeCall);
      }
    },

    async clearActiveCall() {
      const activeCall = this.activeCall;
      this.calls = this.calls.filter(call => !call.isActive);

      if (activeCall) {
        await endClientCall(activeCall);
      }
    },

    dismissCall(callSid) {
      this.calls = this.calls.filter(call => call.callSid !== callSid);
    },

    async handleCallClaimed(data, currentUserId) {
      const claimedByUserId =
        data?.claimed_by_user_id ||
        data?.claimedByUserId ||
        data?.user_id ||
        data?.userId;
      const callData = {
        callSid: data?.call_sid || data?.callSid || data?.call_ref,
        provider: data?.provider || 'fonoster',
        callDirection: data?.call_direction || data?.direction || 'inbound',
        status: 'in_progress',
        conversationId: data?.conversation_id || data?.conversation_display_id,
        conversationDisplayId:
          data?.conversation_display_id || data?.conversation_id,
        conversationDbId: data?.conversation_db_id || data?.conversationDbId,
        communicationThreadId:
          data?.communication_thread_id || data?.communicationThreadId,
        startedAt: data?.started_at || data?.startedAt,
        answeredAt: data?.answered_at || data?.answeredAt,
        operatorClaim: data?.operator_claim || data?.operatorClaim || null,
        browserJoinSupported: false,
        browserJoinUnsupportedReason: 'CALL_ALREADY_CLAIMED',
        logicalCallKey:
          data?.logical_call_key ||
          data?.logicalCallKey ||
          data?.call_group_key ||
          data?.callGroupKey,
      };

      if (
        isPresent(claimedByUserId) &&
        isPresent(currentUserId) &&
        String(claimedByUserId) === String(currentUserId)
      ) {
        this.dismissRelatedFonosterIncomingCalls(callData);
        return;
      }

      const callSids = relatedCallSids(data);
      const matchesClaimedCall = call =>
        callSids.includes(String(call?.callSid)) ||
        isRelatedFonosterInbound(call, callData);
      const removedCalls = this.calls.filter(matchesClaimedCall);
      const existingCall = removedCalls[0] || null;

      this.calls = this.calls.filter(call => !matchesClaimedCall(call));

      const removedBrowserCalls = removedCalls.filter(
        call =>
          NATIVE_BROWSER_SIP_PROVIDERS.has(call.provider) &&
          (call.isActive || call.browserJoined)
      );
      if (removedBrowserCalls.length) {
        await Promise.all(removedBrowserCalls.map(call => endClientCall(call)));
      }

      this.addCall({
        ...(existingCall || {}),
        ...callData,
        callSid: callData.callSid || existingCall?.callSid,
        provider: callData.provider || existingCall?.provider,
        callDirection: callData.callDirection || existingCall?.callDirection,
        isActive: false,
        browserJoined: false,
      });
    },

    dismissRelatedFonosterIncomingCalls(targetCall) {
      this.calls = this.calls.filter(call => {
        if (call.isActive) return true;
        if (sameCallSid(call, targetCall?.callSid)) return true;
        return !isRelatedFonosterInbound(call, targetCall);
      });
    },
  },
});
