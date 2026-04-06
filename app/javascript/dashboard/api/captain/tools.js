/* global axios */
import ApiClient from '../ApiClient';

class CaptainTools extends ApiClient {
  constructor() {
    super('captain/assistants/tools', { accountScoped: true });
  }

  get({ assistantId, scope } = {}) {
    return axios.get(this.url, {
      params: {
        ...(assistantId ? { assistant_id: assistantId } : {}),
        ...(scope ? { scope } : {}),
      },
    });
  }
}

export default new CaptainTools();
