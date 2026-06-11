require 'rails_helper'

RSpec.describe Whatsapp::TokenInspectionService do
  let(:access_token) { 'test-token' }
  let(:waba_id) { 'waba-1' }
  let(:phone_number_id) { 'phone-1' }
  let(:api_client) { instance_double(Whatsapp::FacebookApiClient) }

  before do
    allow(GlobalConfigService).to receive(:load).with('WHATSAPP_APP_ID', '').and_return('app-1')
    allow(GlobalConfigService).to receive(:load).with('WHATSAPP_APP_SECRET', '').and_return('secret-1')
  end

  describe '#perform' do
    it 'marks a valid system user token with WABA and phone access as healthy' do
      allow(api_client).to receive(:debug_token).with(access_token).and_return(
        'data' => {
          'app_id' => 'app-1',
          'type' => 'SYSTEM_USER',
          'is_valid' => true,
          'expires_at' => 0,
          'granular_scopes' => [
            { 'scope' => 'whatsapp_business_management', 'target_ids' => [waba_id] },
            { 'scope' => 'whatsapp_business_messaging', 'target_ids' => [waba_id] }
          ]
        }
      )
      allow(api_client).to receive(:fetch_phone_numbers).with(waba_id).and_return(
        'data' => [{ 'id' => phone_number_id }]
      )

      result = described_class.new(
        access_token: access_token,
        waba_id: waba_id,
        phone_number_id: phone_number_id,
        api_client: api_client
      ).perform

      expect(result).to include(
        'status' => 'healthy',
        'token_type' => 'SYSTEM_USER',
        'never_expires' => true,
        'waba_access' => true,
        'phone_number_access' => true
      )
      expect(result['required_permissions']).to include(
        'whatsapp_business_management' => true,
        'whatsapp_business_messaging' => true
      )
    end

    it 'records expiring user tokens without requiring reauthorization before expiry' do
      allow(api_client).to receive(:debug_token).and_return(
        'data' => {
          'type' => 'USER',
          'is_valid' => true,
          'expires_at' => 10.days.from_now.to_i,
          'scopes' => %w[whatsapp_business_management whatsapp_business_messaging]
        }
      )
      allow(api_client).to receive(:fetch_phone_numbers).with(waba_id).and_return('data' => [{ 'id' => phone_number_id }])

      service = described_class.new(access_token: access_token, waba_id: waba_id, phone_number_id: phone_number_id, api_client: api_client)
      result = service.perform

      expect(result['status']).to eq('expiring')
      expect(service.reauthorization_required?).to be(false)
    end

    it 'requires reauthorization when required WhatsApp permissions are missing' do
      allow(api_client).to receive(:debug_token).and_return(
        'data' => {
          'is_valid' => true,
          'granular_scopes' => [
            { 'scope' => 'whatsapp_business_management', 'target_ids' => [waba_id] }
          ]
        }
      )
      allow(api_client).to receive(:fetch_phone_numbers).with(waba_id).and_return('data' => [{ 'id' => phone_number_id }])

      service = described_class.new(access_token: access_token, waba_id: waba_id, phone_number_id: phone_number_id, api_client: api_client)
      result = service.perform

      expect(result['status']).to eq('permission_missing')
      expect(result['missing_permissions']).to eq(['whatsapp_business_messaging'])
      expect(service.reauthorization_required?).to be(true)
    end

    it 'falls back to graph access when debug_token cannot inspect a token from another app' do
      allow(api_client).to receive(:debug_token).and_raise(StandardError, 'Cannot inspect token')
      allow(api_client).to receive(:fetch_phone_numbers).with(waba_id).and_return('data' => [{ 'id' => phone_number_id }])

      result = described_class.new(access_token: access_token, waba_id: waba_id, phone_number_id: phone_number_id, api_client: api_client).perform

      expect(result['status']).to eq('healthy_unverified')
      expect(result['waba_access']).to be(true)
      expect(result['phone_number_access']).to be(true)
    end

    it 'requires reauthorization when the token belongs to a different Meta App' do
      allow(api_client).to receive(:debug_token).and_return(
        'data' => {
          'app_id' => 'other-app',
          'is_valid' => true,
          'scopes' => %w[whatsapp_business_management whatsapp_business_messaging]
        }
      )
      allow(api_client).to receive(:fetch_phone_numbers).with(waba_id).and_return('data' => [{ 'id' => phone_number_id }])

      service = described_class.new(access_token: access_token, waba_id: waba_id, phone_number_id: phone_number_id, api_client: api_client)
      result = service.perform

      expect(result['status']).to eq('app_id_mismatch')
      expect(result['app_id']).to eq('other-app')
      expect(result['expected_app_id']).to eq('app-1')
      expect(service.reauthorization_required?).to be(true)
    end

    it 'keeps app id mismatch as the primary status when the wrong-app token also lacks permissions' do
      allow(api_client).to receive(:debug_token).and_return(
        'data' => {
          'app_id' => 'other-app',
          'is_valid' => true,
          'scopes' => []
        }
      )
      allow(api_client).to receive(:fetch_phone_numbers).with(waba_id).and_return('data' => [{ 'id' => phone_number_id }])

      result = described_class.new(access_token: access_token, waba_id: waba_id, phone_number_id: phone_number_id, api_client: api_client).perform

      expect(result['status']).to eq('app_id_mismatch')
      expect(result['missing_permissions']).to eq(%w[whatsapp_business_management whatsapp_business_messaging])
    end

    it 'requires reauthorization when the token cannot access the configured phone number' do
      allow(api_client).to receive(:debug_token).and_return(
        'data' => {
          'is_valid' => true,
          'scopes' => %w[whatsapp_business_management whatsapp_business_messaging]
        }
      )
      allow(api_client).to receive(:fetch_phone_numbers).with(waba_id).and_return('data' => [{ 'id' => 'different-phone' }])

      result = described_class.new(access_token: access_token, waba_id: waba_id, phone_number_id: phone_number_id, api_client: api_client).perform

      expect(result['status']).to eq('phone_number_mismatch')
      expect(result['available_phone_number_ids']).to eq(['different-phone'])
    end

    it 'accepts configured phone numbers returned on a later WABA phone-number page' do
      allow(api_client).to receive(:debug_token).and_return(
        'data' => {
          'is_valid' => true,
          'scopes' => %w[whatsapp_business_management whatsapp_business_messaging]
        }
      )
      allow(api_client).to receive(:fetch_phone_numbers).with(waba_id).and_return(
        'data' => [{ 'id' => 'different-phone' }],
        'paging' => { 'next' => 'https://graph.facebook.com/next', 'cursors' => { 'after' => 'cursor-1' } }
      )
      allow(api_client).to receive(:fetch_phone_numbers).with(waba_id, after: 'cursor-1').and_return(
        'data' => [{ 'id' => phone_number_id }]
      )

      result = described_class.new(access_token: access_token, waba_id: waba_id, phone_number_id: phone_number_id, api_client: api_client).perform

      expect(result['status']).to eq('healthy')
      expect(result['phone_number_access']).to be(true)
    end
  end
end
