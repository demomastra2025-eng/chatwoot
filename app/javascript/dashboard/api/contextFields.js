/* global axios */
import ApiClient from './ApiClient';

class ContextFields extends ApiClient {
  constructor() {
    super('context_fields', { accountScoped: true });
  }

  get() {
    return axios.get(this.url);
  }
}

export default new ContextFields();
