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

  describe '#refresh!' do
    let(:hook) do
      instance_double(Integrations::Hook, secret_settings: {
                        'token_sn' => 'old-token-sn',
                        'vtoken_secret' => 'old-secret',
                        'profile_id' => 'profile-1',
                        'organization_id' => 'org-1',
                        'phone_number' => '7012114000'
                      })
    end

    it 'refreshes the adapter session and persists the rotated credentials' do
      allow(client).to receive(:refresh).with(hook: hook).and_return(
        'success' => true,
        'tokenSN' => 'new-token-sn',
        'vtokenSecret' => 'new-secret',
        'profileId' => 'profile-1',
        'organizationId' => 'org-1'
      )
      expect(hook).to receive(:update!) do |attributes|
        persisted = JSON.parse(attributes[:access_token])
        expect(persisted).to include('token_sn' => 'new-token-sn', 'vtoken_secret' => 'new-secret', 'phone_number' => '7012114000')
        expect(attributes[:status]).to eq('enabled')
      end

      expect(service.refresh!(hook: hook)).to eq(hook)
    end

    it 'preserves existing organization context when refresh omits it' do
      allow(client).to receive(:refresh).with(hook: hook).and_return(
        'success' => true,
        'tokenSN' => 'new-token-sn',
        'vtokenSecret' => 'new-secret'
      )
      expect(hook).to receive(:update!) do |attributes|
        persisted = JSON.parse(attributes[:access_token])
        expect(persisted).to include(
          'token_sn' => 'new-token-sn',
          'vtoken_secret' => 'new-secret',
          'profile_id' => 'profile-1',
          'organization_id' => 'org-1'
        )
      end

      service.refresh!(hook: hook)
    end

    it 'does not overwrite credentials when the adapter returns an incomplete session' do
      allow(client).to receive(:refresh).with(hook: hook).and_return('success' => true, 'profileId' => 'profile-1')

      expect(hook).not_to receive(:update!)
      expect { service.refresh!(hook: hook) }.to raise_error(KaspiPay::Error) { |error|
        expect(error.code).to eq('SESSION_REFRESH_INVALID')
      }
    end

    it 'classifies provider status failures as adapter request failures' do
      allow(client).to receive(:refresh).with(hook: hook).and_return(
        'success' => false,
        'statusCode' => 401,
        'message' => 'Unauthorized'
      )

      expect { service.refresh!(hook: hook) }.to raise_error(KaspiPay::Error) { |error|
        expect(error.code).to eq('ADAPTER_REQUEST_FAILED')
      }
    end
  end
end
