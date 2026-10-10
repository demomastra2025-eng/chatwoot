/* global axios */
import ApiClient from '../ApiClient';

const inFlightMetaRequests = new Map();

class ConversationApi extends ApiClient {
  constructor() {
    super('conversations', { accountScoped: true });
  }

  show(id, context = null, options = {}) {
    const url = context ? `${context.baseUrl}/conversations` : this.url;
    return Object.keys(options).length
      ? axios.get(`${url}/${id}`, options)
      : axios.get(`${url}/${id}`);
  }

  // The counts are only needed with the first page, later pages are sent with includeMeta false.
  get({
    inboxId,
    status,
    assigneeType,
    page,
    labels,
    teamId,
    conversationType,
    sortBy,
    updatedWithin,
    crmPipelineId,
    crmStageId,
    appointmentStatus,
    labelsScope,
    teamScope,
    unread,
    includeMeta = true,
  }) {
    return axios.get(this.url, {
      params: {
        inbox_id: inboxId,
        team_id: teamId,
        status,
        assignee_type: assigneeType,
        page,
        labels,
        conversation_type: conversationType,
        sort_by: sortBy,
        updated_within: updatedWithin,
        crm_pipeline_id: crmPipelineId,
        crm_stage_id: crmStageId,
        appointment_status: appointmentStatus,
        labels_scope: labelsScope,
        team_scope: teamScope,
        unread,
        include_meta: includeMeta ? undefined : false,
      },
    });
  }

  filter(payload, { includeMeta = true } = {}) {
    return axios.post(`${this.url}/filter`, payload.queryData, {
      params: {
        page: payload.page,
        crm_pipeline_id: payload.crmPipelineId || payload.crm_pipeline_id,
        crm_stage_id: payload.crmStageId || payload.crm_stage_id,
        appointment_status:
          payload.appointmentStatus || payload.appointment_status,
        labels_scope: payload.labelsScope || payload.labels_scope,
        team_scope: payload.teamScope || payload.team_scope,
        unread: payload.unread,
        include_meta: includeMeta ? undefined : false,
      },
    });
  }

  search({ q }) {
    return axios.get(`${this.url}/search`, {
      params: {
        q,
        page: 1,
      },
    });
  }

  // Search box of the conversation list: the server ignores every list filter, so only the query and page are sent.
  listSearch({ q, page = 1 }) {
    return axios.get(`${this.url}/list_search`, { params: { q, page } });
  }

  toggleStatus({
    conversationId,
    status,
    snoozedUntil = null,
    statusReason = null,
  }) {
    return axios.post(`${this.url}/${conversationId}/toggle_status`, {
      status,
      snoozed_until: snoozedUntil,
      status_reason: statusReason,
    });
  }

  togglePriority({ conversationId, priority }) {
    return axios.post(`${this.url}/${conversationId}/toggle_priority`, {
      priority,
    });
  }

  assignAgent({ conversationId, agentId }) {
    return axios.post(`${this.url}/${conversationId}/assignments`, {
      assignee_id: agentId,
    });
  }

  assignTeam({ conversationId, teamId }) {
    const params = { team_id: teamId };
    return axios.post(`${this.url}/${conversationId}/assignments`, params);
  }

  markMessageRead({ id }) {
    return axios.post(`${this.url}/${id}/update_last_seen`, {
      response_format: 'compact',
    });
  }

  markMessagesUnread({ id }) {
    return axios.post(`${this.url}/${id}/unread`);
  }

  toggleTyping({ conversationId, status, isPrivate }) {
    return axios.post(`${this.url}/${conversationId}/toggle_typing_status`, {
      typing_status: status,
      is_private: isPrivate,
    });
  }

  cancelCaptainResponse({ conversationId }) {
    return axios.post(`${this.url}/${conversationId}/cancel_captain_response`);
  }

  mute(conversationId) {
    return axios.post(`${this.url}/${conversationId}/mute`);
  }

  unmute(conversationId) {
    return axios.post(`${this.url}/${conversationId}/unmute`);
  }

  meta({
    inboxId,
    status,
    assigneeType,
    labels,
    teamId,
    conversationType,
    crmPipelineId,
    crmStageId,
    appointmentStatus,
    labelsScope,
    teamScope,
    unread,
  } = {}) {
    const url = `${this.url}/meta`;
    const params = {
      inbox_id: inboxId,
      status,
      assignee_type: assigneeType,
      labels,
      team_id: teamId,
      conversation_type: conversationType,
      crm_pipeline_id: crmPipelineId,
      crm_stage_id: crmStageId,
      appointment_status: appointmentStatus,
      labels_scope: labelsScope,
      team_scope: teamScope,
      unread,
    };
    // Identical requests that overlap (stats and sidebar counters ask for the same /meta) share one call.
    const requestKey = JSON.stringify([url, params]);
    const currentRequest = inFlightMetaRequests.get(requestKey);
    if (currentRequest) return currentRequest;

    const request = axios.get(url, { params }).finally(() => {
      if (inFlightMetaRequests.get(requestKey) === request) {
        inFlightMetaRequests.delete(requestKey);
      }
    });
    inFlightMetaRequests.set(requestKey, request);
    return request;
  }

  sidebarUnreadCounts() {
    return axios.get(`${this.url}/sidebar_unread_counts`);
  }

  sendEmailTranscript({ conversationId, email }) {
    return axios.post(`${this.url}/${conversationId}/transcript`, { email });
  }

  updateCustomAttributes({ conversationId, customAttributes }) {
    return axios.post(`${this.url}/${conversationId}/custom_attributes`, {
      custom_attributes: customAttributes,
    });
  }

  destroyCustomAttributes({ conversationId, customAttributes }) {
    return axios.post(
      `${this.url}/${conversationId}/destroy_custom_attributes`,
      {
        custom_attributes: customAttributes,
      }
    );
  }

  fetchParticipants(conversationId) {
    return axios.get(`${this.url}/${conversationId}/participants`);
  }

  updateParticipants({ conversationId, userIds }) {
    return axios.patch(`${this.url}/${conversationId}/participants`, {
      user_ids: userIds,
    });
  }

  getAllAttachments(conversationId) {
    return axios.get(`${this.url}/${conversationId}/attachments`);
  }

  getInboxAssistant(conversationId) {
    return axios.get(`${this.url}/${conversationId}/inbox_assistant`);
  }

  delete(conversationId, requestKey, context = null) {
    const url = context ? `${context.baseUrl}/conversations` : this.url;
    return axios.delete(`${url}/${conversationId}`, {
      data: { request_key: requestKey },
      timeout: 10000,
    });
  }
}

export default new ConversationApi();
