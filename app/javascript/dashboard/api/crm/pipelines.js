/* global axios */
import ApiClient from 'dashboard/api/ApiClient';

class CrmPipelinesAPI extends ApiClient {
  constructor() {
    super('crm/pipelines', { accountScoped: true });
  }

  get(params = {}) {
    return axios.get(this.url, { params });
  }

  createStage(pipelineId, data) {
    return axios.post(`${this.url}/${pipelineId}/stages`, data);
  }

  updateStage(stageId, data) {
    return axios.patch(`${this.baseUrl()}/crm/stages/${stageId}`, data);
  }
}

export default new CrmPipelinesAPI();
