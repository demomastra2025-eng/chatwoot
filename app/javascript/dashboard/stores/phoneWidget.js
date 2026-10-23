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

export const SELECTED_INBOX_STORAGE_KEY =
  'onelink:phone-widget-selected-inbox';

const CARRIER_LABELS = {
  altel: 'Altel',
  tele2: 'Tele2',
  kazakhtelecom: 'Казахтелеком',
  kcell: 'Kcell',
  beeline_trunk: 'Билайн',
  beeline: 'Билайн',
};

const PROVIDER_LABELS = {
  sipuni: 'Sipuni',
  binotel: 'Binotel',
  beeline: 'Beeline',
  wazo: 'Wazo / Asterisk',
  asterisk_analog: 'Wazo / Asterisk',
  twilio: 'Twilio',
  whatsapp_cloud: 'WhatsApp',
  whatsapp: 'WhatsApp',
};

export const phoneLineProviderLabel = inbox => {
  if (!inbox) return '';
  if (
    inbox.channel_type === 'Channel::Whatsapp' ||
    String(inbox.provider || '')
      .toLowerCase()
      .includes('whatsapp')
  ) {
    return 'WhatsApp';
  }
  const carrierKind = String(
    inbox.carrier_kind ||
      inbox.provider_config?.carrier_kind ||
      inbox.telephony?.carrier_kind ||
      ''
  )
    .trim()
    .toLowerCase();
  if (carrierKind && CARRIER_LABELS[carrierKind]) {
    return CARRIER_LABELS[carrierKind];
  }
  const provider = String(inbox.provider || inbox.telephony?.provider || '')
    .trim()
    .toLowerCase();
  return PROVIDER_LABELS[provider] || inbox.provider || '';
};

const readStoredSelectedInboxId = () => {
  try {
    return window.localStorage?.getItem(SELECTED_INBOX_STORAGE_KEY) || null;
  } catch {
    return null;
  }
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
    // Currently selected outbound line in PhoneWidget (shared with VoiceCallButton).
    selectedInboxId: readStoredSelectedInboxId(),
    // Live status of each phone line by inboxId: { [inboxId]: 'ready' | 'disconnected' | ... }
    linesStatusById: {},
  }),

  actions: {
    publishSipState({
      available = false,
      status = 'disconnected',
      linesStatusById = null,
    } = {}) {
      this.available = Boolean(available);
      this.status = status;
      if (linesStatusById && typeof linesStatusById === 'object') {
        this.linesStatusById = { ...linesStatusById };
      } else if (!available) {
        this.linesStatusById = {};
      }
    },

    setSelectedInboxId(inboxId) {
      const normalized =
        inboxId !== null && inboxId !== undefined && inboxId !== ''
          ? String(inboxId)
          : null;
      this.selectedInboxId = normalized;
      try {
        if (normalized !== null) {
          window.localStorage?.setItem(SELECTED_INBOX_STORAGE_KEY, normalized);
        } else {
          window.localStorage?.removeItem(SELECTED_INBOX_STORAGE_KEY);
        }
      } catch {
        // Ignore storage errors
      }
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

