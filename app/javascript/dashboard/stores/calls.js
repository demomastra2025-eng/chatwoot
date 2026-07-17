import { defineStore } from 'pinia';
import { TERMINAL_STATUSES } from 'dashboard/helper/voice';

const isPresent = value =>
  value !== undefined && value !== null && value !== '';

const operatorClaimUserId = claim =>
  claim?.user_id ||
  claim?.userId ||
  claim?.claimed_by_user_id ||
  claim?.claimedByUserId;

const sameValue = (left, right) =>
  isPresent(left) && isPresent(right) && String(left) === String(right);

const callSessionKey = call =>
  call?.janusSessionKey ||
  call?.janus_session_key ||
  call?.sessionKey ||
  call?.session_key;
const callSipProfileId = call =>
  call?.sipProfileId ||
  call?.sip_profile_id ||
  call?.operatorClaim?.sip_profile_id;
const callInboxId = call => call?.inboxId || call?.inbox_id;
const sameKnownScopeValue = (left, right) =>
  !isPresent(left) || !isPresent(right) || sameValue(left, right);
const suppliedScopeValueMatches = (actual, expected) =>
  !isPresent(expected) || (isPresent(actual) && sameValue(actual, expected));
const callScopeMatches = (call, candidate) =>
  sameKnownScopeValue(call?.provider, candidate?.provider) &&
  sameKnownScopeValue(callSessionKey(call), callSessionKey(candidate)) &&
  sameKnownScopeValue(callSipProfileId(call), callSipProfileId(candidate)) &&
  sameKnownScopeValue(callInboxId(call), callInboxId(candidate));
const callScopeMatchesExactly = (call, candidate) =>
  suppliedScopeValueMatches(call?.provider, candidate?.provider) &&
  suppliedScopeValueMatches(callSessionKey(call), callSessionKey(candidate)) &&
  suppliedScopeValueMatches(
    callSipProfileId(call),
    callSipProfileId(candidate)
  ) &&
  suppliedScopeValueMatches(callInboxId(call), callInboxId(candidate));

const sameCallSid = (call, candidate) => {
  const candidateCall =
    candidate && typeof candidate === 'object' ? candidate : null;
  const candidateCallSid =
    candidateCall?.callSid || candidateCall?.call_sid || candidate;
  if (!isPresent(call?.callSid) || !isPresent(candidateCallSid)) return false;
  if (!sameValue(call.callSid, candidateCallSid)) return false;
  return callScopeMatches(call, candidateCall);
};

const scopedCallSidMatches = (calls, call, target = {}) => {
  const candidates = calls.filter(item => sameCallSid(item, target));
  return candidates.length === 1 && sameCallSid(call, target);
};

const callLogicalKey = call =>
  call?.logicalCallKey ||
  call?.logical_call_key ||
  call?.callGroupKey ||
  call?.call_group_key;

const scopedCallKeys = entries =>
  entries.flatMap(([scope, ...values]) =>
    values.filter(isPresent).map(value => `${scope}:${String(value)}`)
  );

const callHasSessionScope = call =>
  [callSessionKey(call), callSipProfileId(call), callInboxId(call)].some(
    isPresent
  );
const callScopesMatchForDeduplication = (call, candidate) => {
  if (!callHasSessionScope(call) && !callHasSessionScope(candidate))
    return true;

  return (
    callScopeMatchesExactly(call, candidate) &&
    callScopeMatchesExactly(candidate, call)
  );
};

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

const sameNativeSipConversation = (
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

  if (isInboundCall(call) || isInboundCall(callData)) return false;
  if (!callScopesMatchForDeduplication(call, callData)) return false;

  return hasSharedConversationKey(call, callData);
};

const sameNativeSipInboundBranch = (call, callData) => {
  if (!isNativeBrowserSipCall(call) || !isNativeBrowserSipCall(callData)) {
    return false;
  }
  if (call?.provider !== callData?.provider) return false;
  if (!isInboundCall(call) || !isInboundCall(callData)) return false;
  if (!callScopesMatchForDeduplication(call, callData)) return false;

  return sameValue(callLogicalKey(call), callLogicalKey(callData));
};

const sameNativeSipLogicalCall = (call, callData) => {
  if (!isNativeBrowserSipCall(call) || !isNativeBrowserSipCall(callData)) {
    return false;
  }
  if (call?.provider !== callData?.provider) return false;
  if (!isInboundCall(call) || !isInboundCall(callData)) return false;

  return sameValue(callLogicalKey(call), callLogicalKey(callData));
};

const normalizedPhoneIdentity = value => {
  const raw = String(value || '').trim();
  if (!raw) return null;

  const sipUser = raw.match(/sip:\+?(\d+)/i)?.[1];
  let digits = sipUser || raw.replace(/\D/g, '');
  if (digits.startsWith('00')) digits = digits.slice(2);
  if (digits.length === 11 && digits.startsWith('8')) {
    digits = `7${digits.slice(1)}`;
  }
  return digits || null;
};

const callFromIdentity = call =>
  normalizedPhoneIdentity(
    call?.fromNumber ||
      call?.from_number ||
      call?.caller?.phone_number ||
      call?.caller?.phoneNumber
  );
const callToIdentity = call =>
  normalizedPhoneIdentity(call?.toNumber || call?.to_number);

const sameNativeSipInboundCustomer = (
  call,
  callData,
  { allowPartialScope = false } = {}
) => {
  if (!isNativeBrowserSipCall(call) || !isNativeBrowserSipCall(callData)) {
    return false;
  }
  if (call?.provider !== callData?.provider) return false;
  if (!isInboundCall(call) || !isInboundCall(callData)) return false;
  if (!sameKnownScopeValue(call?.accountId, callData?.accountId)) return false;

  const scopeMatches = allowPartialScope
    ? callScopeMatches(call, callData)
    : callScopesMatchForDeduplication(call, callData);
  if (!scopeMatches) return false;

  const fromIdentity = callFromIdentity(call);
  const candidateFromIdentity = callFromIdentity(callData);
  if (!fromIdentity || fromIdentity !== candidateFromIdentity) return false;

  const toIdentity = callToIdentity(call);
  const candidateToIdentity = callToIdentity(callData);
  return (
    !toIdentity || !candidateToIdentity || toIdentity === candidateToIdentity
  );
};

const sameReplaceableNativeSipIncomingCall = (call, callData) =>
  !call?.isActive &&
  !callData?.isActive &&
  sameNativeSipInboundCustomer(call, callData);

const sameLiveCall = (call, callData) =>
  sameCallSid(call, callData) ||
  sameNativeSipInboundBranch(call, callData) ||
  sameNativeSipConversation(call, callData, { allowCallSidMismatch: true });

const terminalSuppressionKeys = (
  call,
  { includeUnscopedFallback = false } = {}
) => {
  const providerScope = isPresent(call?.provider)
    ? String(call.provider)
    : 'unknown';
  const sessionScope = scopedCallKeys([
    ['session', callSessionKey(call)],
    ['sip_profile', callSipProfileId(call)],
    ['inbox', callInboxId(call)],
  ]).join('|');
  const identityScope = sessionScope || 'unscoped';
  const callSid = call?.callSid || call?.call_sid || call?.call_ref;
  const logicalKey = callLogicalKey(call);
  const keys = [
    isPresent(callSid)
      ? `sid:${providerScope}:${identityScope}:${callSid}`
      : null,
    isPresent(logicalKey)
      ? `logical:${providerScope}:${identityScope}:${logicalKey}`
      : null,
  ].filter(Boolean);
  if (includeUnscopedFallback && sessionScope) {
    if (isPresent(callSid)) {
      keys.push(`sid:${providerScope}:unscoped:${callSid}`);
    }
    if (isPresent(logicalKey)) {
      keys.push(`logical:${providerScope}:unscoped:${logicalKey}`);
    }
  }
  return keys;
};

const nonTerminalCallStatus = status => !TERMINAL_STATUSES.includes(status);

const isRelatedNativeSipInbound = (call, targetCall) =>
  sameNativeSipInboundBranch(call, targetCall);

const visibleIncomingCalls = calls => calls.filter(call => !call.isActive);

const hasOwn = (object, key) =>
  Object.prototype.hasOwnProperty.call(object || {}, key);

const buildCallState = (callData, existingCall = null) => {
  const isSameProviderCall = sameCallSid(existingCall, callData);
  const preserveExistingCallSid =
    existingCall &&
    !isSameProviderCall &&
    sameNativeSipInboundBranch(existingCall, callData);
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
    serverManagedVoiceCall: displayValue('serverManagedVoiceCall'),
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

const webphoneCallScope = call => ({
  ...(call || {}),
  callRef: call?.callRef || call?.callSid || call?.call_sid,
  janusCallRef: call?.janusCallRef || call?.janus_call_ref,
  sessionKey:
    call?.sessionKey ||
    call?.session_key ||
    call?.janusSessionKey ||
    call?.janus_session_key,
});

const endClientCall = async callOrProvider => {
  try {
    const WebphoneClient = await loadWebphoneClient();
    await WebphoneClient.endClientCall(
      typeof callOrProvider === 'object'
        ? webphoneCallScope(callOrProvider)
        : callOrProvider
    );
  } catch {
    // Browser-side cleanup is best effort; call state is already removed.
  }
};

const cleanupClaimedBrowserCall = async call => {
  try {
    const WebphoneClient = await loadWebphoneClient();
    const scope = webphoneCallScope(call);
    if (
      typeof WebphoneClient.hasPendingIncomingCall === 'function' &&
      WebphoneClient.hasPendingIncomingCall(scope)
    ) {
      await WebphoneClient.rejectIncomingCall({
        ...scope,
        callRef: scope.janusCallRef ? null : scope.callRef,
      });
      return;
    }

    if (call?.isActive || call?.browserJoined) {
      await WebphoneClient.endClientCall(scope);
    }
  } catch {
    // The claim fence is authoritative; local SIP cleanup is best effort.
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
      browserJoinUnsupportedReason,
      serverManagedVoiceCall,
      accountId,
      conversationDbId,
      conversationDisplayId,
      communicationThreadId,
      contactId,
      logicalCallKey,
      logicalCallTerminal,
      numberRef,
      currentUserId,
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
        browserJoinUnsupportedReason,
        serverManagedVoiceCall,
      };
      const sidCandidates = this.calls.filter(call =>
        sameCallSid(call, callData)
      );
      if (sidCandidates.length > 1) return;

      if (TERMINAL_STATUSES.includes(status)) {
        this.rememberTerminalCall(callData);
        this.removeCall(callSid, {
          conversationId,
          provider,
          callDirection,
          logicalCallKey,
          inboxId,
          sipProfileId,
          janusSessionKey,
          forceLogicalTerminal: logicalCallTerminal === true,
        });
        return;
      }

      if (this.isRecentlyTerminalCall(callData)) return;

      const call = this.calls.find(
        item => sameCallSid(item, callData) || sameLiveCall(item, callData)
      );
      const resolvedProvider = call?.provider || provider;
      const resolvedCallDirection = call?.callDirection || callDirection;
      const claimedByUserId =
        operatorClaimUserId(operatorClaim) ||
        operatorClaimUserId(call?.operatorClaim);
      const claimedByAnotherOperator =
        status === 'in_progress' &&
        isPresent(claimedByUserId) &&
        isPresent(currentUserId) &&
        String(claimedByUserId) !== String(currentUserId);

      if (claimedByAnotherOperator) {
        this.rememberTerminalCall(callData);
        this.removeCall(call?.callSid || callSid, {
          conversationId,
          provider: resolvedProvider,
          callDirection: resolvedCallDirection,
          logicalCallKey,
          inboxId,
          sipProfileId,
          janusSessionKey,
          cleanupClaimedBrowserCall: true,
        });
        return;
      }

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
          browserJoinUnsupportedReason,
          serverManagedVoiceCall,
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
              browserJoinUnsupportedReason,
              serverManagedVoiceCall,
            });
          }
          const activeCall = call || {
            callSid,
            provider: resolvedProvider,
            inboxId,
            sipProfileId,
            janusSessionKey,
          };
          this.setCallActive(activeCall.callSid, resolvedProvider, activeCall);
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
            : browserJoinUnsupportedReason || 'CALL_IN_PROGRESS',
          serverManagedVoiceCall,
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

      const existingCallIndexes = this.calls.reduce((indexes, call, index) => {
        if (sameLiveCall(call, callData)) indexes.push(index);
        return indexes;
      }, []);
      const replaceableIncomingCallIndexes = existingCallIndexes.length
        ? []
        : this.calls.reduce((indexes, call, index) => {
            if (sameReplaceableNativeSipIncomingCall(call, callData)) {
              indexes.push(index);
            }
            return indexes;
          }, []);
      const replacingIncomingDuplicates =
        replaceableIncomingCallIndexes.length > 0;
      let candidateIndexes = replacingIncomingDuplicates
        ? replaceableIncomingCallIndexes
        : existingCallIndexes;
      if (candidateIndexes.length > 1 && !replacingIncomingDuplicates) {
        candidateIndexes = candidateIndexes.filter(index =>
          callScopeMatchesExactly(this.calls[index], callData)
        );
        if (candidateIndexes.length !== 1) return;
      }
      const [existingCallIndex = -1] = candidateIndexes;

      if (existingCallIndex >= 0) {
        const existingCall = this.calls[existingCallIndex];
        if (
          existingCall?.isActive &&
          !sameCallSid(existingCall, callData) &&
          isRelatedNativeSipInbound(existingCall, callData)
        ) {
          this.dismissRelatedNativeSipIncomingCalls(existingCall);
          return;
        }
        const replacedActiveCall =
          existingCall?.isActive && !sameCallSid(existingCall, callData);
        const mergedCall = buildCallState(callData, existingCall);
        this.calls = this.calls.reduce((calls, call, index) => {
          if (index === existingCallIndex) {
            calls.push(mergedCall);
            return calls;
          }

          if (
            !sameLiveCall(call, mergedCall) &&
            !(
              replacingIncomingDuplicates &&
              sameReplaceableNativeSipIncomingCall(call, mergedCall)
            )
          ) {
            calls.push(call);
          }
          return calls;
        }, []);
        if (replacedActiveCall) endClientCall(existingCall);
        return;
      }

      const activeCall = this.calls.find(call => call.isActive);
      if (activeCall && isRelatedNativeSipInbound(activeCall, callData)) {
        this.dismissRelatedNativeSipIncomingCalls(activeCall);
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
      const keys = terminalSuppressionKeys(callData, {
        includeUnscopedFallback: true,
      });
      if (!keys.length) return;

      this.pruneTerminalCallKeys();
      const expiresAt = Date.now() + TERMINAL_CALL_SUPPRESSION_MS;
      keys.forEach(key => {
        this.terminalCallKeys[key] = expiresAt;
      });
    },

    isRecentlyTerminalCall(callData) {
      const keys = terminalSuppressionKeys(callData, {
        includeUnscopedFallback: !callHasSessionScope(callData),
      });
      if (
        callHasSessionScope(callData) &&
        isNativeBrowserSipCall(callData) &&
        isInboundCall(callData) &&
        isPresent(callLogicalKey(callData))
      ) {
        keys.push(
          `logical:${String(callData.provider)}:unscoped:${String(callLogicalKey(callData))}`
        );
      }
      if (!keys.length) return false;

      this.pruneTerminalCallKeys();
      const now = Date.now();
      return keys.some(key => (this.terminalCallKeys[key] || 0) > now);
    },

    markBrowserJoinUnsupported(callSid, provider, details = {}, scope = {}) {
      const target = { ...scope, callSid, provider };
      this.calls = this.calls.map(call =>
        scopedCallSidMatches(this.calls, call, target)
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

    markBrowserJoined(callSid, provider, scope = {}) {
      const target = { ...scope, callSid, provider };
      this.calls = this.calls.map(call =>
        scopedCallSidMatches(this.calls, call, target)
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
      {
        conversationId,
        provider,
        callDirection,
        logicalCallKey,
        inboxId,
        sipProfileId,
        janusSessionKey,
        cleanupClaimedBrowserCall: cleanupClaimed = false,
        forceLogicalTerminal = false,
      } = {}
    ) {
      const target = {
        callSid,
        conversationId,
        provider,
        callDirection,
        logicalCallKey,
        inboxId,
        sipProfileId,
        janusSessionKey,
      };
      const sidCandidates = this.calls.filter(call =>
        sameCallSid(call, target)
      );
      const matchesLogicalBranch = call =>
        sameNativeSipLogicalCall(call, target) &&
        (forceLogicalTerminal || !call.isActive || sameCallSid(call, target));
      if (sidCandidates.length > 1 && !this.calls.some(matchesLogicalBranch)) {
        return;
      }
      const directMatches = this.calls.filter(
        call => sameCallSid(call, target) || matchesLogicalBranch(call)
      );
      let matchingCalls = directMatches;
      if (!matchingCalls.length) {
        matchingCalls = this.calls.filter(call =>
          sameNativeSipConversation(call, target)
        );
        if (matchingCalls.length > 1) return;
      }
      const matchingCallSet = new Set(matchingCalls);
      const [callToRemove] = matchingCalls;
      this.calls = this.calls.filter(call => !matchingCallSet.has(call));

      if (callToRemove && cleanupClaimed) {
        await cleanupClaimedBrowserCall(callToRemove);
      } else if (callToRemove?.isActive) {
        await endClientCall(callToRemove);
      }
    },

    setCallActive(callSid, provider = null, scope = {}) {
      const target = { ...scope, callSid, provider };
      const activeCall = this.calls.find(call =>
        scopedCallSidMatches(this.calls, call, target)
      );
      if (!activeCall) return;
      this.calls = this.calls.map(call => ({
        ...call,
        isActive: scopedCallSidMatches(this.calls, call, target),
      }));
      if (activeCall && sameNativeSipInboundBranch(activeCall, activeCall)) {
        this.dismissRelatedNativeSipIncomingCalls(activeCall);
      }
    },

    async clearActiveCall(expectedCall = null) {
      const activeCall = this.activeCall;
      if (
        expectedCall &&
        (!activeCall ||
          !sameValue(activeCall.callSid, expectedCall.callSid) ||
          !callScopeMatchesExactly(activeCall, expectedCall))
      ) {
        return false;
      }
      this.calls = this.calls.filter(call => !call.isActive);

      if (activeCall) {
        await endClientCall(activeCall);
      }
      return true;
    },

    dismissCall(callSid, provider = null, scope = {}) {
      const target = { ...scope, callSid, provider };
      this.calls = this.calls.filter(
        call => !scopedCallSidMatches(this.calls, call, target)
      );
    },

    async handleCallClaimed(data, currentUserId) {
      const eventClaimedByUserId =
        data?.claimed_by_user_id ||
        data?.claimedByUserId ||
        data?.user_id ||
        data?.userId ||
        operatorClaimUserId(data?.operator_claim || data?.operatorClaim);
      const callData = {
        callSid: data?.call_sid || data?.callSid || data?.call_ref,
        accountId: data?.account_id || data?.accountId,
        provider: data?.provider,
        inboxId: data?.inbox_id || data?.inboxId,
        sipProfileId: data?.sip_profile_id || data?.sipProfileId,
        janusSessionKey:
          data?.janus_session_key ||
          data?.janusSessionKey ||
          data?.session_key ||
          data?.sessionKey,
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
        fromNumber: data?.from_number || data?.fromNumber,
        toNumber: data?.to_number || data?.toNumber,
        caller: data?.caller,
        operatorClaim: data?.operator_claim || data?.operatorClaim || null,
        browserJoinSupported: false,
        browserJoinUnsupportedReason: 'CALL_ALREADY_CLAIMED',
        logicalCallKey:
          data?.logical_call_key ||
          data?.logicalCallKey ||
          data?.call_group_key ||
          data?.callGroupKey,
      };
      const callSids = relatedCallSids(data);
      const sidMatchesClaim = call => callSids.includes(String(call?.callSid));
      const candidateProviders = [
        ...new Set(
          this.calls
            .filter(sidMatchesClaim)
            .map(call => call.provider)
            .filter(isPresent)
            .map(String)
        ),
      ];
      if (!isPresent(callData.provider) && candidateProviders.length > 1) {
        return;
      }
      const claimProvider = callData.provider || candidateProviders[0];
      const scopedCallData = { ...callData, provider: claimProvider };
      const providerMatchesClaim = call =>
        !isPresent(claimProvider) ||
        !isPresent(call?.provider) ||
        sameValue(call.provider, claimProvider);
      const scopeMatchesClaim = call =>
        providerMatchesClaim(call) && callScopeMatches(call, scopedCallData);
      const claimHasSessionScope = [
        callSessionKey(scopedCallData),
        callSipProfileId(scopedCallData),
        callInboxId(scopedCallData),
      ].some(isPresent);
      const matchesClaimedCall = call =>
        scopeMatchesClaim(call) &&
        (sidMatchesClaim(call) ||
          sameNativeSipLogicalCall(call, scopedCallData) ||
          sameNativeSipInboundCustomer(call, scopedCallData, {
            allowPartialScope: true,
          }));
      const matchedClaimCalls = this.calls.filter(matchesClaimedCall);
      if (matchedClaimCalls.length > 1) {
        if (
          claimHasSessionScope &&
          matchedClaimCalls.some(
            call => !callScopeMatchesExactly(call, scopedCallData)
          )
        ) {
          return;
        }
        if (
          !claimHasSessionScope &&
          !isPresent(callLogicalKey(scopedCallData))
        ) {
          const scopeIdentities = matchedClaimCalls.map(call => {
            const parts = [
              callSessionKey(call),
              callSipProfileId(call),
              callInboxId(call),
            ];
            return parts.some(isPresent)
              ? parts
                  .map(value => (isPresent(value) ? String(value) : ''))
                  .join('|')
              : null;
          });
          const knownScopeIdentities = new Set(scopeIdentities.filter(Boolean));
          if (
            knownScopeIdentities.size > 1 ||
            (knownScopeIdentities.size === 1 && scopeIdentities.includes(null))
          ) {
            return;
          }
        }
      }
      const trackedCall = matchedClaimCalls[0];
      const claimedByUserId =
        eventClaimedByUserId || operatorClaimUserId(trackedCall?.operatorClaim);

      // Missing identity is unknown, not evidence that another operator won.
      // Never suppress or terminate a local media leg without an explicit owner.
      if (!isPresent(claimedByUserId) || !isPresent(currentUserId)) return;

      if (String(claimedByUserId) === String(currentUserId)) {
        this.dismissRelatedNativeSipIncomingCalls(scopedCallData);
        return;
      }

      const removedCalls = this.calls.filter(matchesClaimedCall);
      const suppressionProvider =
        claimProvider || removedCalls.find(call => call.provider)?.provider;
      callSids.forEach(callSid => {
        this.rememberTerminalCall({
          ...callData,
          callSid,
          provider: suppressionProvider,
        });
      });
      if (!callSids.length) {
        this.rememberTerminalCall({
          ...callData,
          provider: suppressionProvider,
        });
      }

      this.calls = this.calls.filter(call => !matchesClaimedCall(call));

      const removedBrowserCalls = removedCalls.filter(call =>
        NATIVE_BROWSER_SIP_PROVIDERS.has(call.provider)
      );
      if (removedBrowserCalls.length) {
        await Promise.all(
          removedBrowserCalls.map(call => cleanupClaimedBrowserCall(call))
        );
      }

      // The winning operator owns the in-progress call. For every other
      // browser this event is terminal for the ringing UI: do not recreate an
      // unanswerable card after removing the local branches above.
    },

    dismissRelatedNativeSipIncomingCalls(targetCall) {
      this.calls = this.calls.filter(call => {
        if (call.isActive) return true;
        if (sameCallSid(call, targetCall)) return true;
        const sameLogicalCall =
          callScopeMatches(call, targetCall) &&
          isRelatedNativeSipInbound(call, targetCall);
        const sameCustomerCall = sameNativeSipInboundCustomer(
          call,
          targetCall,
          { allowPartialScope: true }
        );
        return !sameLogicalCall && !sameCustomerCall;
      });
    },
  },
});
