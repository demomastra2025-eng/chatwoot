import { defineStore } from 'pinia';

// Colours of the SIP status dot, shared by the phone header and the sidebar
// phone button so both always show the same state.
const PHONE_WIDGET_STATUS_COLORS = {
  ready: 'bg-n-teal-9',
  ownerTab: 'bg-n-teal-9',
  connecting: 'bg-n-amber-9',
  standby: 'bg-n-slate-9',
  disconnected: 'bg-n-slate-9',
  error: 'bg-n-ruby-9',
};

export const phoneWidgetStatusColor = status =>
  PHONE_WIDGET_STATUS_COLORS[status] || PHONE_WIDGET_STATUS_COLORS.error;

// UI state of the phone widget shared with the sidebar phone button. The
// mounted PhoneWidget owns the SIP sessions and publishes their state here;
// hiding the widget never touches the sessions.
export const usePhoneWidgetStore = defineStore('phoneWidget', {
  state: () => ({
    // The employee has a browser SIP line (same rule as the widget itself).
    available: false,
    status: 'disconnected',
    // The employee hid the phone while a call was in progress.
    callDismissed: false,
    // Outbound calls being prepared before they reach the calls store.
    preparingOutboundCalls: 0,
  }),

  actions: {
    publishSipState({ available = false, status = 'disconnected' } = {}) {
      this.available = Boolean(available);
      this.status = status;
    },

    setCallDismissed(dismissed) {
      this.callDismissed = Boolean(dismissed);
    },

    beginOutboundCall() {
      this.preparingOutboundCalls += 1;
    },

    finishOutboundCall() {
      this.preparingOutboundCalls = Math.max(
        this.preparingOutboundCalls - 1,
        0
      );
    },
  },
});
