/* global axios */
import ApiClient from '../ApiClient';

class CaptainSkills extends ApiClient {
  constructor() {
    super('captain/assistants/skills', { accountScoped: true });
  }

  get({ assistantId } = {}) {
    return axios.get(this.url, {
      params: assistantId ? { assistant_id: assistantId } : {},
    });
  }
}

export default new CaptainSkills();
