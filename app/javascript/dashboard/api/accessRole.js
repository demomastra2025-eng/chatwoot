/* global axios */

import ApiClient from './ApiClient';

class AccessRoleAPI extends ApiClient {
  constructor() {
    super('access_roles', { accountScoped: true });
  }

  delete(id, data) {
    return axios.delete(`${this.url}/${id}`, { data });
  }
}

export default new AccessRoleAPI();
