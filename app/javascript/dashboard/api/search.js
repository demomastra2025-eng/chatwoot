/* global axios */
import ApiClient from './ApiClient';

const requestConfig = (params, signal) => ({
  params,
  ...(signal && { signal }),
});

class SearchAPI extends ApiClient {
  constructor() {
    super('search', { accountScoped: true });
  }

  get({ q, signal }) {
    return axios.get(this.url, requestConfig({ q }, signal));
  }

  contacts({ q, page = 1, since, until, signal }) {
    return axios.get(
      `${this.url}/contacts`,
      requestConfig({ q, page, since, until }, signal)
    );
  }

  conversations({ q, page = 1, since, until, signal }) {
    return axios.get(
      `${this.url}/conversations`,
      requestConfig({ q, page, since, until, compact: true }, signal)
    );
  }

  messages({ q, page = 1, since, until, from, inboxId, signal }) {
    const params = { q, page, since, until, from, inbox_id: inboxId };
    return axios.get(`${this.url}/messages`, requestConfig(params, signal));
  }

  articles({ q, page = 1, since, until, signal }) {
    return axios.get(
      `${this.url}/articles`,
      requestConfig({ q, page, since, until }, signal)
    );
  }
}

export default new SearchAPI();
