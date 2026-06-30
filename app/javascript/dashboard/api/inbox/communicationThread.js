/* global axios */
import ApiClient from '../ApiClient';
import { buildCreatePayload } from './message';

class CommunicationThreadApi extends ApiClient {
  constructor() {
    super('communication_threads', { accountScoped: true });
  }

  get({
    inboxId,
    status,
    assigneeType,
    page,
    labels,
    teamId,
    sortBy,
    crmPipelineId,
    crmStageId,
    appointmentStatus,
    labelsScope,
    teamScope,
    unread,
  } = {}) {
    return axios.get(this.url, {
      params: {
        inbox_id: inboxId,
        status,
        assignee_type: assigneeType,
        page,
        labels,
        team_id: teamId,
        sort_by: sortBy,
        crm_pipeline_id: crmPipelineId,
        crm_stage_id: crmStageId,
        appointment_status: appointmentStatus,
        labels_scope: labelsScope,
        team_scope: teamScope,
        unread,
      },
    });
  }

  meta({
    inboxId,
    status,
    assigneeType,
    labels,
    teamId,
    sortBy,
    crmPipelineId,
    crmStageId,
    appointmentStatus,
    labelsScope,
    teamScope,
    unread,
  } = {}) {
    return axios.get(`${this.url}/meta`, {
      params: {
        inbox_id: inboxId,
        status,
        assignee_type: assigneeType,
        labels,
        team_id: teamId,
        sort_by: sortBy,
        crm_pipeline_id: crmPipelineId,
        crm_stage_id: crmStageId,
        appointment_status: appointmentStatus,
        labels_scope: labelsScope,
        team_scope: teamScope,
        unread,
      },
    });
  }

  filter(payload) {
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
      },
    });
  }

  channels(id) {
    return axios.get(`${this.url}/${id}/channels`);
  }

  attachments(id) {
    return axios.get(`${this.url}/${id}/attachments`);
  }

  labels(id) {
    return axios.get(`${this.url}/${id}/labels`);
  }

  updateLabels(id, labels) {
    return axios.post(`${this.url}/${id}/labels`, { labels });
  }

  deleteConversations(id, conversationIds) {
    return axios.delete(`${this.url}/${id}/conversations`, {
      data: { conversation_ids: conversationIds },
    });
  }

  markMessageRead({ id }) {
    return axios.post(`${this.url}/${id}/update_last_seen`);
  }

  markMessagesUnread({ id }) {
    return axios.post(`${this.url}/${id}/unread`);
  }

  messages(threadId, params = {}) {
    const normalizedParams = Object.fromEntries(
      Object.entries(params).filter(
        ([, value]) => value !== undefined && value !== null
      )
    );

    if (
      normalizedParams.after &&
      Number(normalizedParams.after) === Number(normalizedParams.before)
    ) {
      delete normalizedParams.after;
    }

    return axios.get(`${this.url}/${threadId}/messages`, {
      params: normalizedParams,
    });
  }

  createMessage(
    threadId,
    {
      conversation_id: conversationId,
      message,
      private: isPrivate,
      contentAttributes,
      echo_id: echoId,
      files,
      ccEmails = '',
      bccEmails = '',
      toEmails = '',
      templateParams,
      channelKey,
      targetInboxId,
      inboxId,
      targetContactInboxId,
      contactInboxId,
      contentKind,
    }
  ) {
    return axios({
      method: 'post',
      url: `${this.url}/${threadId}/messages`,
      data: buildCreatePayload({
        message,
        isPrivate,
        contentAttributes,
        echoId,
        files,
        ccEmails,
        bccEmails,
        toEmails,
        templateParams,
        extraParams: {
          conversation_id: conversationId,
          channel_key: channelKey,
          target_inbox_id: targetInboxId,
          inbox_id: inboxId,
          target_contact_inbox_id: targetContactInboxId,
          contact_inbox_id: contactInboxId,
          content_kind: contentKind,
        },
      }),
    });
  }
}

export default new CommunicationThreadApi();
