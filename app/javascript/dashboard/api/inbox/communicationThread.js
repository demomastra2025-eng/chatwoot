/* global axios */
import ApiClient from '../ApiClient';
import { buildCreatePayload } from './message';

const inFlightMetaRequests = new Map();
const inFlightListRequests = new Map();

const fetchListOnce = (key, fetch) => {
  const currentRequest = inFlightListRequests.get(key);
  if (currentRequest) return currentRequest;

  const request = fetch().finally(() => {
    if (inFlightListRequests.get(key) === request) {
      inFlightListRequests.delete(key);
    }
  });
  inFlightListRequests.set(key, request);
  return request;
};

class CommunicationThreadApi extends ApiClient {
  constructor() {
    super('communication_threads', { accountScoped: true });
  }

  // eslint-disable-next-line class-methods-use-this
  invalidateListRequests() {
    inFlightListRequests.clear();
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
    includeMeta = true,
  } = {}) {
    const url = this.url;
    const options = {
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
        include_meta: includeMeta,
      },
    };
    return fetchListOnce(JSON.stringify([url, options]), () =>
      axios.get(url, options)
    );
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
    const url = `${this.url}/meta`;
    const params = {
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
    };
    const requestKey = JSON.stringify([url, params]);
    const currentRequest = inFlightMetaRequests.get(requestKey);
    if (currentRequest) return currentRequest;

    let request;
    request = axios.get(url, { params }).finally(() => {
      if (inFlightMetaRequests.get(requestKey) === request) {
        inFlightMetaRequests.delete(requestKey);
      }
    });
    inFlightMetaRequests.set(requestKey, request);
    return request;
  }

  filter(payload) {
    const url = `${this.url}/filter`;
    const options = {
      params: {
        page: payload.page,
        crm_pipeline_id: payload.crmPipelineId || payload.crm_pipeline_id,
        crm_stage_id: payload.crmStageId || payload.crm_stage_id,
        appointment_status:
          payload.appointmentStatus || payload.appointment_status,
        labels_scope: payload.labelsScope || payload.labels_scope,
        team_scope: payload.teamScope || payload.team_scope,
        unread: payload.unread,
        sort_by: payload.sortBy || payload.sort_by,
        include_meta: Number(payload.page || 1) === 1,
      },
    };
    return fetchListOnce(
      JSON.stringify([url, payload.queryData, options]),
      () => axios.post(url, payload.queryData, options)
    );
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
