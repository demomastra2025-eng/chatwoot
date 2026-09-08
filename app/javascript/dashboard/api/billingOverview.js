import ApiClient from './ApiClient';

class BillingOverviewAPI extends ApiClient {
  constructor() {
    super('billing_overview', { accountScoped: true });
  }
}

export default new BillingOverviewAPI();
