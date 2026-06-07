import { defineStore } from 'pinia';
import { TERMINAL_STATUSES } from 'dashboard/helper/voice';

const isPresent = value =>
  value !== undefined && value !== null && value !== '';

const sameValue = (left, right) =>
  isPresent(left) && isPresent(right) && String(left) === String(right);

const sameCallSid = (call, callSid) => sameValue(call?.callSid, callSid);

const sameFonosterConversation = (call, callData) => {
  if (call?.provider !== 'fonoster' || callData?.provider !== 'fonoster') {
    return false;
  }

  return sameValue(call?.conversationId, callData?.conversationId);
};

const sameLiveCall = (call, callData) =>
  sameCallSid(call, callData?.callSid) ||
  sameFonosterConversation(call, callData);

const buildCallState = (callData, existingCall = null) => {
  const isSameProviderCall = sameCallSid(existingCall, callData?.callSid);

  return {
    ...(existingCall || {}),
    ...(callData || {}),
    isActive: isSameProviderCall ? existingCall?.isActive || false : false,
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
    handleCallStatusChanged({ callSid, status, conversationId, provider }) {
      if (TERMINAL_STATUSES.includes(status)) {
        this.removeCall(callSid, { conversationId, provider });
        return;
      }

      if (status === 'in_progress') {
        const call = this.calls.find(
          item =>
            sameCallSid(item, callSid) ||
            sameFonosterConversation(item, { conversationId, provider })
        );
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

    markBrowserJoinUnsupported(callSid, provider) {
      this.calls = this.calls.map(call =>
        call.callSid === callSid
          ? {
              ...call,
              browserJoinSupported: false,
              provider: provider || call.provider,
            }
          : call
      );
    },

    async removeCall(callSid, { conversationId, provider } = {}) {
      const target = { callSid, conversationId, provider };
      const matchesTarget = call =>
        sameCallSid(call, target.callSid) ||
        sameFonosterConversation(call, target);
      const callToRemove = this.calls.find(matchesTarget);
      this.calls = this.calls.filter(c => !matchesTarget(c));

      if (callToRemove?.isActive) {
        await endClientCall(callToRemove.provider);
      }
    },

    setCallActive(callSid) {
      this.calls = this.calls.map(call => ({
        ...call,
        isActive: call.callSid === callSid,
      }));
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
  },
});
