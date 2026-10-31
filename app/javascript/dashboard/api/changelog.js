import ApiClient from './ApiClient';

class ChangelogApi extends ApiClient {
  constructor() {
    super('changelog', { apiVersion: 'v1' });
  }

  // Retain the response contract for cached callers. OneLink has no JSON news
  // feed configured; product news remains available through its public link.
  // eslint-disable-next-line class-methods-use-this
  fetchFromHub() {
    return Promise.resolve({ data: { posts: [] } });
  }
}

export default new ChangelogApi();
