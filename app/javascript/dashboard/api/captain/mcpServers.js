/* global axios */
import ApiClient from '../ApiClient';

class CaptainMcpServers extends ApiClient {
  constructor() {
    super('captain/mcp_servers', { accountScoped: true });
  }

  get({ page = 1, searchKey } = {}) {
    return axios.get(this.url, {
      params: { page, searchKey },
    });
  }

  show(id) {
    return axios.get(`${this.url}/${id}`);
  }

  create(data = {}) {
    return axios.post(this.url, { mcp_server: data });
  }

  update(id, data = {}) {
    return axios.put(`${this.url}/${id}`, { mcp_server: data });
  }

  test({ mcpServer = {} } = {}) {
    return axios.post(`${this.url}/test`, {
      mcp_server: mcpServer,
    });
  }

  surface(id) {
    return axios.get(`${this.url}/${id}/surface`);
  }

  readResource(id, { uri } = {}) {
    return axios.post(`${this.url}/${id}/read_resource`, { uri });
  }

  fetchResourceTemplate(id, { name, arguments: templateArguments } = {}) {
    return axios.post(`${this.url}/${id}/fetch_resource_template`, {
      name,
      arguments: templateArguments,
    });
  }

  fetchPrompt(id, { name, arguments: promptArguments } = {}) {
    return axios.post(`${this.url}/${id}/fetch_prompt`, {
      name,
      arguments: promptArguments,
    });
  }

  taskGet(id, { taskId } = {}) {
    return axios.post(`${this.url}/${id}/task_get`, { task_id: taskId });
  }

  taskResult(id, { taskId } = {}) {
    return axios.post(`${this.url}/${id}/task_result`, { task_id: taskId });
  }

  taskCancel(id, { taskId } = {}) {
    return axios.post(`${this.url}/${id}/task_cancel`, { task_id: taskId });
  }

  startOAuth(id, { returnUrl } = {}) {
    return axios.post(`${this.url}/${id}/oauth_start`, {
      return_url: returnUrl,
    });
  }

  disconnectOAuth(id) {
    return axios.delete(`${this.url}/${id}/oauth_disconnect`);
  }

  delete(id) {
    return axios.delete(`${this.url}/${id}`);
  }
}

export default new CaptainMcpServers();
