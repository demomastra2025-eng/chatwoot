/* global axios */
import ApiClient from '../ApiClient';

class CaptainToolAccess extends ApiClient {
  constructor() {
    super('captain/assistants/tool_access', { accountScoped: true });
  }

  get({ assistantId } = {}) {
    return axios.get(this.url, {
      params: assistantId ? { assistant_id: assistantId } : {},
    });
  }
}

export default new CaptainToolAccess();
