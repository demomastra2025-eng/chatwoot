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

  reorderStages(pipelineId, stageIds) {
    return axios.patch(`${this.url}/${pipelineId}/reorder_stages`, {
      stage_ids: stageIds,
    });
  }

  deletePipeline(pipelineId) {
    return this.delete(pipelineId);
  }

  deleteStage(stageId) {
    return axios.delete(`${this.baseUrl()}/crm/stages/${stageId}`);
  }
}

export default new CrmPipelinesAPI();
