/* global axios */
import ApiClient from './ApiClient';

class McpSettings extends ApiClient {
  constructor() {
    super('mcp_settings', { accountScoped: true });
  }

  get(config = {}) {
    return axios.get(this.url, config);
  }

  update(data, config = {}) {
    return axios.put(this.url, data, config);
  }
}

export default new McpSettings();
