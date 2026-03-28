/* global axios */
import ApiClient from '../ApiClient';

class CaptainContextFields extends ApiClient {
  constructor() {
    super('captain/assistants/context_fields', { accountScoped: true });
  }

  get({ assistantId } = {}) {
    return axios.get(this.url, {
      params: assistantId ? { assistant_id: assistantId } : {},
    });
  }
}

export default new CaptainContextFields();
