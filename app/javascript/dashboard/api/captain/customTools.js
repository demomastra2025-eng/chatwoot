/* global axios */
import ApiClient from '../ApiClient';

class CaptainCustomTools extends ApiClient {
  constructor() {
    super('captain/custom_tools', { accountScoped: true });
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
    return axios.post(this.url, {
      custom_tool: data,
    });
  }

  update(id, data = {}) {
    return axios.put(`${this.url}/${id}`, {
      custom_tool: data,
    });
  }

  preview({ customTool = {}, testPayload = {} } = {}) {
    return axios.post(`${this.url}/test`, {
      custom_tool: customTool,
      test_payload: testPayload,
      preview_only: true,
    });
  }

  test({ customTool = {}, testPayload = {} } = {}) {
    return axios.post(`${this.url}/test`, {
      custom_tool: customTool,
      test_payload: testPayload,
      preview_only: false,
    });
  }

  delete(id) {
    return axios.delete(`${this.url}/${id}`);
  }
}

export default new CaptainCustomTools();
