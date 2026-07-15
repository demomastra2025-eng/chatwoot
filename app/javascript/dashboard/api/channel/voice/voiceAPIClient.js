/* global axios */
import ApiClient from '../../ApiClient';
import ContactsAPI from '../../contacts';

class VoiceAPI extends ApiClient {
  constructor() {
    super('voice', { accountScoped: true });
  }

  // eslint-disable-next-line class-methods-use-this
  initiateCall(contactId, inboxId) {
    return ContactsAPI.initiateCall(contactId, inboxId).then(r => r.data);
  }

  leaveConference(inboxId, conversationId) {
    return axios
      .delete(`${this.baseUrl()}/inboxes/${inboxId}/conference`, {
        params: { conversation_id: conversationId },
      })
      .then(r => r.data);
  }

  joinConference({ conversationId, inboxId, callSid }) {
    return axios
      .post(`${this.baseUrl()}/inboxes/${inboxId}/conference`, {
        conversation_id: conversationId,
        call_sid: callSid,
      })
      .then(r => r.data);
  }

  getWebphoneToken(inboxId = null) {
    if (inboxId) {
      return axios
        .get(`${this.baseUrl()}/inboxes/${inboxId}/conference/token`)
        .then(r => r.data);
    }

    return axios
      .post(`${this.baseUrl()}/telephony/webphone/token`)
      .then(r => r.data.payload || r.data);
  }

  getNativeWebphoneToken(inboxId = null) {
    return axios
      .post(`${this.baseUrl()}/telephony/webphone/token`, {
        ...(inboxId ? { inbox_id: inboxId } : {}),
      })
      .then(r => r.data.payload || r.data);
  }

  updateWebphonePresence(registered, { inboxId = null, context = {} } = {}) {
    return axios
      .post(`${this.baseUrl()}/telephony/webphone/presence`, {
        registered,
        ...context,
        ...(inboxId ? { inbox_id: inboxId } : {}),
      })
      .then(r => r.data.payload || r.data);
  }

  updateWebphonePresenceOnUnload(
    registered,
    { inboxId = null, context = {} } = {}
  ) {
    const commonHeaders = axios.defaults?.headers?.common;
    const sourceHeaders =
      typeof commonHeaders?.toJSON === 'function'
        ? commonHeaders.toJSON()
        : commonHeaders || {};
    const headers = Object.fromEntries(
      Object.entries(sourceHeaders).filter(
        ([, value]) => value !== undefined && value !== null
      )
    );

    return window
      .fetch(`${this.baseUrl()}/telephony/webphone/presence`, {
        method: 'POST',
        headers: {
          ...headers,
          Accept: 'application/json',
          'Content-Type': 'application/json',
        },
        credentials: 'same-origin',
        keepalive: true,
        body: JSON.stringify({
          registered,
          ...context,
          ...(inboxId ? { inbox_id: inboxId } : {}),
        }),
      })
      .then(response => {
        if (!response.ok) throw new Error('webphone_presence_release_failed');
        return null;
      });
  }

  reportBrowserSipIncoming(payload = {}) {
    return axios
      .post(`${this.baseUrl()}/telephony/webphone/incoming`, payload)
      .then(r => r.data.payload || r.data);
  }

  claimIncomingCall(callRef) {
    return axios
      .post(`${this.baseUrl()}/telephony/webphone/claim`, { call_ref: callRef })
      .then(r => r.data.payload || r.data);
  }

  reportBrowserSipAnswered(callRef, { answered_at: answeredAt } = {}) {
    return axios
      .post(`${this.baseUrl()}/telephony/webphone/answered`, {
        call_ref: callRef,
        answered_at: answeredAt,
      })
      .then(r => r.data.payload || r.data);
  }

  rejectIncomingCall(
    callRef,
    { status = 'rejected', reason, ended_at: endedAt } = {}
  ) {
    return axios
      .post(`${this.baseUrl()}/telephony/webphone/reject`, {
        call_ref: callRef,
        status,
        reason,
        ...(endedAt ? { ended_at: endedAt } : {}),
      })
      .then(r => r.data.payload || r.data);
  }

  showTelephonyCall(callRef) {
    return axios
      .get(`${this.baseUrl()}/telephony/calls/${encodeURIComponent(callRef)}`)
      .then(r => r.data.payload || r.data);
  }

  uploadWebphoneRecording(callRef, blob, metadata = {}) {
    const formData = new FormData();
    formData.append('recording', blob, `call-${Date.now()}.webm`);
    Object.entries(metadata).forEach(([key, value]) => {
      if (value === null || value === undefined || value === '') return;

      formData.append(key, value);
    });

    return axios
      .post(
        `${this.baseUrl()}/telephony/calls/${encodeURIComponent(callRef)}/upload_recording`,
        formData,
        { headers: { 'Content-Type': 'multipart/form-data' } }
      )
      .then(r => r.data.payload || r.data);
  }

  getToken(inboxId) {
    return this.getWebphoneToken(inboxId);
  }

  getReadiness() {
    return axios
      .get(`${this.baseUrl()}/telephony/resources/readiness`)
      .then(r => r.data);
  }

  getVirtualPbxTemplates() {
    return axios
      .get(`${this.baseUrl()}/telephony/virtual_pbx_channels/templates`)
      .then(r => r.data);
  }

  getVirtualPbxReadiness(inboxId, { includeDiagnostics = false } = {}) {
    return axios
      .post(
        `${this.baseUrl()}/telephony/virtual_pbx_channels/${inboxId}/readiness_check`,
        { include_diagnostics: includeDiagnostics }
      )
      .then(r => r.data);
  }

  getVirtualPbxStatus(inboxId, { includeDiagnostics = false } = {}) {
    return axios
      .get(
        `${this.baseUrl()}/telephony/virtual_pbx_channels/${inboxId}/status`,
        {
          params: { include_diagnostics: includeDiagnostics },
        }
      )
      .then(r => r.data);
  }

  getVirtualPbxProvisioningPlan(
    inboxId,
    { operation = 'update', includeDiagnostics = false } = {}
  ) {
    return axios
      .post(
        `${this.baseUrl()}/telephony/virtual_pbx_channels/${inboxId}/provisioning_plan`,
        { operation, include_diagnostics: includeDiagnostics }
      )
      .then(r => r.data);
  }

  provisionVirtualPbxChannel(
    inboxId,
    { remoteCommit = false, includeDiagnostics = false } = {}
  ) {
    return axios
      .post(
        `${this.baseUrl()}/telephony/virtual_pbx_channels/${inboxId}/provision`,
        { remote_commit: remoteCommit, include_diagnostics: includeDiagnostics }
      )
      .then(r => r.data);
  }

  reconcileVirtualPbxChannel(inboxId, { includeDiagnostics = false } = {}) {
    return axios
      .post(
        `${this.baseUrl()}/telephony/virtual_pbx_channels/${inboxId}/reconcile`,
        { include_diagnostics: includeDiagnostics }
      )
      .then(r => r.data);
  }

  getVirtualPbxProvisioningRuns(inboxId) {
    return axios
      .get(
        `${this.baseUrl()}/telephony/virtual_pbx_channels/${inboxId}/provisioning_runs`
      )
      .then(r => r.data);
  }

  createVirtualPbxChannel(
    payload,
    { dryRun = false, remoteCommit = false } = {}
  ) {
    return axios
      .post(`${this.baseUrl()}/telephony/virtual_pbx_channels`, {
        virtual_pbx_channel: payload,
        dry_run: dryRun,
        remote_commit: remoteCommit,
      })
      .then(r => r.data);
  }

  updateVirtualPbxChannel(
    inboxId,
    payload,
    { dryRun = false, remoteCommit = false } = {}
  ) {
    return axios
      .patch(`${this.baseUrl()}/telephony/virtual_pbx_channels/${inboxId}`, {
        virtual_pbx_channel: payload,
        dry_run: dryRun,
        remote_commit: remoteCommit,
      })
      .then(r => r.data);
  }

  deleteVirtualPbxChannel(
    inboxId,
    { confirm = false, dryRun = true, remoteCommit = false } = {}
  ) {
    return axios
      .delete(`${this.baseUrl()}/telephony/virtual_pbx_channels/${inboxId}`, {
        params: {
          confirm,
          dry_run: dryRun,
          remote_commit: remoteCommit,
        },
      })
      .then(r => r.data);
  }

  updateNumberRoute(numberRef, payload) {
    return axios
      .post(
        `${this.baseUrl()}/telephony/numbers/${encodeURIComponent(numberRef)}/route`,
        payload
      )
      .then(r => r.data);
  }
}

export default new VoiceAPI();
