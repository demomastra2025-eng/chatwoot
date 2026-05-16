require 'rails_helper'

RSpec.describe KaspiPay::AuthService do
  let(:account) { instance_double(Account) }
  let(:client) { instance_double(KaspiPay::Client) }
  let(:service) { described_class.new(account: account, client: client) }

  describe '#send_phone' do
    it 'sends Kaspi the local 10-digit cashier phone when the UI passes a +7 phone' do
      allow(client).to receive(:send_phone)
        .with(process_id: 'process-1', phone_number: '7012114000')
        .and_return('processId' => 'process-1', 'success' => true, 'view' => 'EnterOtp')

      result = service.send_phone(process_id: 'process-1', phone_number: '+7 701 211 40 00')

      expect(result).to include(success: true, process_id: 'process-1', view: 'EnterOtp')
    end

    it 'passes provider error details back to the controller for UI display' do
      allow(client).to receive(:send_phone)
        .with(process_id: 'process-1', phone_number: '7012114000')
        .and_return('processId' => 'process-1', 'success' => false, 'error' => 'UserPhoneNumberDoesNotBelongToAnyOperator')

      result = service.send_phone(process_id: 'process-1', phone_number: '77012114000')

      expect(result).to include(success: false, error: 'UserPhoneNumberDoesNotBelongToAnyOperator')
    end
  end

  describe '#verify_otp' do
    it 'stores the normalized cashier phone when Kaspi does not return one' do
      allow(client).to receive(:verify_otp)
        .with(process_id: 'process-1', otp: '1234', phone_number: '7012114000')
        .and_return('tokenSN' => 'token-sn', 'vtokenSecret' => 'secret', 'profileId' => 'profile-1')

      result = service.verify_otp(process_id: 'process-1', otp: '1234', phone_number: '87012114000')

      expect(result).to include(phone_number: '7012114000')
    end
  end
end
