/* global axios */
import ApiClient from '../ApiClient';

class ConversationApi extends ApiClient {
  constructor() {
    super('conversations', { accountScoped: true });
  }

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
    labelsScope,
    teamScope,
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
        labels_scope: labelsScope,
        team_scope: teamScope,
      },
    });
  }

  filter(payload) {
    return axios.post(`${this.url}/filter`, payload.queryData, {
      params: {
        page: payload.page,
        crm_pipeline_id: payload.crmPipelineId || payload.crm_pipeline_id,
        crm_stage_id: payload.crmStageId || payload.crm_stage_id,
        labels_scope: payload.labelsScope || payload.labels_scope,
        team_scope: payload.teamScope || payload.team_scope,
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

  toggleStatus({ conversationId, status, snoozedUntil = null }) {
    return axios.post(`${this.url}/${conversationId}/toggle_status`, {
      status,
      snoozed_until: snoozedUntil,
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
    return axios.post(`${this.url}/${id}/update_last_seen`);
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
    labelsScope,
    teamScope,
  }) {
    return axios.get(`${this.url}/meta`, {
      params: {
        inbox_id: inboxId,
        status,
        assignee_type: assigneeType,
        labels,
        team_id: teamId,
        conversation_type: conversationType,
        crm_pipeline_id: crmPipelineId,
        crm_stage_id: crmStageId,
        labels_scope: labelsScope,
        team_scope: teamScope,
      },
    });
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

  delete(conversationId) {
    return axios.delete(`${this.url}/${conversationId}`);
  }
}

export default new ConversationApi();
