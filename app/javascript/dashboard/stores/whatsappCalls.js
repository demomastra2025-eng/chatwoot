import { defineStore } from 'pinia';

// Module-scoped (non-reactive) state for outbound call WebRTC objects.
// These cannot be in Pinia state because RTCPeerConnection/MediaStream are not serializable.
// Used ONLY in legacy (browser-direct) mode. In server-relay mode outbound calls
// go through the same inbound WebRTC path via handleAgentOffer.
const outboundCall = { pc: null, stream: null, audio: null, callId: null };
const PENDING_AGENT_OFFER_TTL_MS = 30000;
const MAX_PENDING_AGENT_OFFERS = 20;

function pendingOfferKeys(callLike = {}) {
  return [
    callLike.id ? `id:${callLike.id}` : null,
    callLike.callId ? `call:${callLike.callId}` : null,
    callLike.call_id ? `call:${callLike.call_id}` : null,
  ].filter(Boolean);
}

function normalizeAgentOffer(data = {}) {
  const sdpOffer = data.sdp_offer || data.sdpOffer;
  if (!sdpOffer) return null;

  return {
    id: data.id,
    call_id: data.call_id || data.callId,
    sdp_offer: sdpOffer,
    ice_servers: data.ice_servers || data.iceServers || [],
  };
}

export function getOutboundCallState() {
  return outboundCall;
}

export function setOutboundCallProperty(key, value) {
  outboundCall[key] = value;
}

export function cleanupOutboundCall() {
  if (outboundCall.pc) outboundCall.pc.close();
  if (outboundCall.stream) {
    outboundCall.stream.getTracks().forEach(t => t.stop());
  }
  if (outboundCall.audio) {
    outboundCall.audio.srcObject = null;
    outboundCall.audio.remove();
  }
  outboundCall.pc = null;
  outboundCall.stream = null;
  outboundCall.audio = null;
  outboundCall.callId = null;
}

export const useWhatsappCallsStore = defineStore('whatsappCalls', {
  state: () => ({
    // Incoming ringing calls waiting for agent action
    incomingCalls: [],
    // The single active call (accepted + audio connected)
    activeCall: null,
    // Cleanup callback registered by the composable — called when a call ends externally
    cleanupCallback: null,
    // True while the agent is reconnecting to an active call after page reload
    isReconnecting: false,
    // Seconds already elapsed when reconnecting — timer resumes from this offset
    callTimerOffset: 0,
    // Agent offers can race ahead of activeCall creation. Keep them briefly
    // in-memory by both Rails call id and provider call id so accept/initiate
    // responses can consume the earliest available offer exactly once.
    pendingAgentOffers: {},
  }),

  getters: {
    hasIncomingCall: state => state.incomingCalls.length > 0,
    hasActiveCall: state => state.activeCall !== null,
    hasWhatsappCall: state =>
      state.incomingCalls.length > 0 || state.activeCall !== null,
    firstIncomingCall: state => state.incomingCalls[0] || null,

    // Returns true when the active call is operating through the media server
    // (server-relay mode). Detected by the absence of sdpOffer in the call data
    // — in legacy mode the incoming call ActionCable event includes sdpOffer.
    isMediaServerEnabled() {
      return this.activeCall?.serverRelay === true;
    },
  },

  actions: {
    addIncomingCall(callData) {
      const exists = this.incomingCalls.some(c => c.callId === callData.callId);
      if (exists) return;
      this.incomingCalls.push(callData);
    },

    removeIncomingCall(callId) {
      this.incomingCalls = this.incomingCalls.filter(c => c.callId !== callId);
    },

    setActiveCall(callData) {
      this.activeCall = callData;
    },

    updateActiveCall(updates) {
      if (this.activeCall) {
        this.activeCall = { ...this.activeCall, ...updates };
      }
    },

    clearActiveCall() {
      this.activeCall = null;
      this.callTimerOffset = 0;
      this.isReconnecting = false;
    },

    markActiveCallConnected() {
      if (this.activeCall) {
        this.activeCall = { ...this.activeCall, status: 'connected' };
      }
    },

    registerCleanupCallback(callback) {
      this.cleanupCallback = callback;
    },

    setReconnecting(value) {
      this.isReconnecting = value;
    },

    setTimerOffset(seconds) {
      this.callTimerOffset = seconds;
    },

    prunePendingAgentOffers() {
      const now = Date.now();
      const entries = Object.entries(this.pendingAgentOffers).filter(
        ([, record]) => record.expiresAt > now
      );
      this.pendingAgentOffers = Object.fromEntries(
        entries.slice(-MAX_PENDING_AGENT_OFFERS)
      );
    },

    storePendingAgentOffer(data) {
      const offer = normalizeAgentOffer(data);
      if (!offer) return;

      this.prunePendingAgentOffers();
      const record = {
        offer,
        expiresAt: Date.now() + PENDING_AGENT_OFFER_TTL_MS,
      };
      const updates = {};
      pendingOfferKeys({ id: offer.id, callId: offer.call_id }).forEach(key => {
        updates[key] = record;
      });
      this.pendingAgentOffers = { ...this.pendingAgentOffers, ...updates };
      this.prunePendingAgentOffers();
    },

    consumePendingAgentOffer(callLike) {
      this.prunePendingAgentOffers();
      const keys = pendingOfferKeys(callLike);
      const key = keys.find(candidate => this.pendingAgentOffers[candidate]);
      if (!key) return null;

      const record = this.pendingAgentOffers[key];
      const next = { ...this.pendingAgentOffers };
      keys.forEach(candidate => delete next[candidate]);
      pendingOfferKeys({
        id: record.offer.id,
        callId: record.offer.call_id,
      }).forEach(candidate => delete next[candidate]);
      this.pendingAgentOffers = next;
      return record.offer;
    },

    clearPendingAgentOffer(callLike) {
      const keys = pendingOfferKeys(callLike);
      const matchingRecords = keys
        .map(key => this.pendingAgentOffers[key])
        .filter(Boolean);
      const next = { ...this.pendingAgentOffers };
      keys.forEach(key => delete next[key]);
      matchingRecords.forEach(record => {
        pendingOfferKeys({
          id: record.offer.id,
          callId: record.offer.call_id,
        }).forEach(key => delete next[key]);
      });
      this.pendingAgentOffers = next;
    },

    handleCallAcceptedByOther(callId) {
      this.removeIncomingCall(callId);
      this.clearPendingAgentOffer({ callId });
    },

    handleCallEnded(callId) {
      this.removeIncomingCall(callId);
      this.clearPendingAgentOffer({ callId });
      if (this.activeCall?.callId === callId) {
        // Invoke cleanup BEFORE clearing activeCall so the callback can
        // check isMediaServerEnabled (which depends on activeCall.serverRelay)
        if (this.cleanupCallback) {
          this.cleanupCallback();
        }
        this.activeCall = null;
        this.callTimerOffset = 0;
        this.isReconnecting = false;
      }
      if (outboundCall.callId === callId) {
        cleanupOutboundCall();
      }
    },
  },
});
