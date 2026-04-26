import { defineStore } from 'pinia';
import { TERMINAL_STATUSES } from 'dashboard/helper/voice';

const buildCallState = (callData, existingCall = null) => ({
  ...(existingCall || {}),
  ...(callData || {}),
  isActive: existingCall?.isActive || false,
  browserJoinSupported:
    callData?.browserJoinSupported ??
    existingCall?.browserJoinSupported ??
    null,
});

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
    handleCallStatusChanged({ callSid, status }) {
      if (TERMINAL_STATUSES.includes(status)) {
        this.removeCall(callSid);
      }
    },

    addCall(callData) {
      if (!callData?.callSid) return;

      const existingCall = this.calls.find(
        call => call.callSid === callData.callSid
      );

      if (existingCall) {
        this.calls = this.calls.map(call =>
          call.callSid === callData.callSid
            ? buildCallState(callData, call)
            : call
        );
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

    async removeCall(callSid) {
      const callToRemove = this.calls.find(c => c.callSid === callSid);
      this.calls = this.calls.filter(c => c.callSid !== callSid);

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
