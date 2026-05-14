import ApiClient from './ApiClient';

class KaspiPayPaymentsAPI extends ApiClient {
  constructor() {
    super('kaspi_pay/payments', { accountScoped: true });
  }
}

export default new KaspiPayPaymentsAPI();
