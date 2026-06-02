/* global axios */
import ApiClient from '../ApiClient';

class CaptainSkills extends ApiClient {
  constructor() {
    super('captain/assistants/skills', { accountScoped: true });
    this.workspaceResource = 'captain/skills';
  }

  get workspaceUrl() {
    return `${this.baseUrl()}/${this.workspaceResource}`;
  }

  get({ assistantId } = {}) {
    return axios.get(this.url, {
      params: assistantId ? { assistant_id: assistantId } : {},
    });
  }

  listWorkspace({ search } = {}) {
    return axios.get(this.workspaceUrl, {
      params: search ? { search } : {},
    });
  }

  createWorkspace(data = {}) {
    return axios.post(this.workspaceUrl, { skill: data });
  }

  updateWorkspace(id, data = {}) {
    return axios.patch(`${this.workspaceUrl}/${id}`, { skill: data });
  }

  importWorkspace(url) {
    return axios.post(`${this.workspaceUrl}/import`, { url });
  }

  deleteWorkspace(id) {
    return axios.delete(`${this.workspaceUrl}/${id}`);
  }
}

export default new CaptainSkills();
