import ApiClient from './ApiClient';

class AccessRoleAPI extends ApiClient {
  constructor() {
    super('access_roles', { accountScoped: true });
  }
}

export default new AccessRoleAPI();
