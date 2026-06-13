/* global axios */
import ApiClient from '../ApiClient';
import { buildCreatePayload } from './message';

class CommunicationThreadApi extends ApiClient {
  constructor() {
    super('communication_threads', { accountScoped: true });
  }

  get({ inboxId, status, assigneeType, page, labels, teamId, sortBy } = {}) {
    return axios.get(this.url, {
      params: {
        inbox_id: inboxId,
        status,
        assignee_type: assigneeType,
        page,
        labels,
        team_id: teamId,
        sort_by: sortBy,
      },
    });
  }

  meta({ inboxId, status, assigneeType, labels, teamId, sortBy } = {}) {
    return axios.get(`${this.url}/meta`, {
      params: {
        inbox_id: inboxId,
        status,
        assignee_type: assigneeType,
        labels,
        team_id: teamId,
        sort_by: sortBy,
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
