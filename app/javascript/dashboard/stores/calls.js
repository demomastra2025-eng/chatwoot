import { defineStore } from 'pinia';
import WebphoneClient from 'dashboard/api/channel/voice/webphoneClient';
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

    removeCall(callSid) {
      const callToRemove = this.calls.find(c => c.callSid === callSid);
      if (callToRemove?.isActive) {
        WebphoneClient.endClientCall(callToRemove.provider);
      }
      this.calls = this.calls.filter(c => c.callSid !== callSid);
    },

    setCallActive(callSid) {
      this.calls = this.calls.map(call => ({
        ...call,
        isActive: call.callSid === callSid,
      }));
    },

    clearActiveCall() {
      WebphoneClient.endClientCall(this.activeCall?.provider);
      this.calls = this.calls.filter(call => !call.isActive);
    },

    dismissCall(callSid) {
      this.calls = this.calls.filter(call => call.callSid !== callSid);
    },
  },
});
