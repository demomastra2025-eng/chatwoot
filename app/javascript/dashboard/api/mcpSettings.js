/* global axios */
import ApiClient from './ApiClient';

class McpSettings extends ApiClient {
  constructor() {
    super('mcp_settings', { accountScoped: true });
  }

  get() {
    return axios.get(this.url);
  }

  update(data) {
    return axios.put(this.url, data);
  }
}

export default new McpSettings();
