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

const callConversationKeys = call =>
  [
    call?.conversationId,
    call?.conversationDisplayId,
    call?.conversationDbId,
    call?.conversation_id,
    call?.conversation_display_id,
    call?.conversation_db_id,
  ]
    .filter(isPresent)
    .map(value => String(value));

const hasSharedConversationKey = (call, callData) => {
  const callKeys = callConversationKeys(call);
  const callDataKeys = callConversationKeys(callData);
  return callKeys.some(key => callDataKeys.includes(key));
};

const isFonosterCall = call => call?.provider === 'fonoster';

const isInboundCall = call => {
  const direction = call?.callDirection || call?.direction;
  return direction === 'inbound';
};

const sameFonosterConversation = (
  call,
  callData,
  { allowCallSidMismatch = false } = {}
) => {
  if (call?.provider !== 'fonoster' || callData?.provider !== 'fonoster') {
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
  if (!isFonosterCall(call) || !isFonosterCall(callData)) return false;
  if (!isInboundCall(call) || !isInboundCall(callData)) return false;

  return sameValue(callLogicalKey(call), callLogicalKey(callData));
};

const sameLiveCall = (call, callData) =>
  sameCallSid(call, callData?.callSid) ||
  sameFonosterInboundBranch(call, callData) ||
  sameFonosterConversation(call, callData, { allowCallSidMismatch: true });

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
    accountId: displayValue('accountId'),
    conversationDbId: displayValue('conversationDbId'),
    conversationDisplayId: displayValue('conversationDisplayId'),
    contactId: displayValue('contactId'),
    logicalCallKey: displayValue('logicalCallKey'),
    numberRef: displayValue('numberRef'),
    fromNumber: displayValue('fromNumber'),
    toNumber: displayValue('toNumber'),
    caller: displayValue('caller'),
    operatorClaim: displayValue('operatorClaim'),
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

const endClientCall = async provider => {
  try {
    const WebphoneClient = await loadWebphoneClient();
    await WebphoneClient.endClientCall(provider);
  } catch {
    // Browser-side cleanup is best effort; call state is already removed.
  }
};

export const useCallsStore = defineStore('calls', {
  state: () => ({
    calls: [],
  }),

  getters: {
    activeCall: state => state.calls.find(call => call.isActive) || null,
    hasActiveCall: state => state.calls.some(call => call.isActive),
    incomingCalls: state => state.calls.filter(call => !call.isActive),
    hasIncomingCall: state => state.calls.some(call => !call.isActive),
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
      fromNumber,
      toNumber,
      caller,
      operatorClaim,
      accountId,
      conversationDbId,
      conversationDisplayId,
      contactId,
      logicalCallKey,
      numberRef,
    }) {
      if (TERMINAL_STATUSES.includes(status)) {
        this.removeCall(callSid, {
          conversationId,
          provider,
          callDirection,
          logicalCallKey,
        });
        return;
      }

      const callData = {
        callSid,
        accountId,
        conversationId,
        conversationDbId,
        conversationDisplayId,
        inboxId,
        provider,
        callDirection,
        senderId,
        contactId,
        logicalCallKey,
        numberRef,
        fromNumber,
        toNumber,
      };
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
          caller,
          operatorClaim,
        });
      }

      if (status === 'in_progress') {
        if (
          resolvedProvider === 'fonoster' &&
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
              caller,
              operatorClaim,
            });
          }
          this.setCallActive(call?.callSid || callSid);
          return;
        }
        if (resolvedProvider === 'fonoster') {
          this.dismissRelatedFonosterIncomingCalls({
            ...callData,
            provider: resolvedProvider,
            callDirection: resolvedCallDirection || 'inbound',
          });
        }
        if (call && !call.isActive) this.dismissCall(call.callSid);
      }
    },

    addCall(callData) {
      if (!callData?.callSid) return;

      const existingCallIndex = this.calls.findIndex(call =>
        sameLiveCall(call, callData)
      );

      if (existingCallIndex >= 0) {
        const existingCall = this.calls[existingCallIndex];
        if (
          existingCall?.isActive &&
          !sameCallSid(existingCall, callData.callSid) &&
          sameFonosterInboundBranch(existingCall, callData)
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
        if (replacedActiveCall) endClientCall(existingCall.provider);
        return;
      }

      this.calls.push(buildCallState(callData));
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
        await endClientCall(callToRemove.provider);
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
        await endClientCall(activeCall.provider);
      }
    },

    dismissCall(callSid) {
      this.calls = this.calls.filter(call => call.callSid !== callSid);
    },

    dismissRelatedFonosterIncomingCalls(targetCall) {
      this.calls = this.calls.filter(call => {
        if (call.isActive) return true;
        if (sameCallSid(call, targetCall?.callSid)) return true;
        return !sameFonosterInboundBranch(call, targetCall);
      });
    },
  },
});
