require 'rails_helper'

describe Whatsapp::TokenValidationService do
  let(:access_token) { 'test_access_token' }
  let(:waba_id) { 'test_waba_id' }
  let(:phone_number_id) { 'test_phone_number_id' }
  let(:service) { described_class.new(access_token, waba_id, phone_number_id: phone_number_id) }

  describe '#perform' do
    context 'when token health is valid' do
      let(:token_health) do
        {
          'status' => 'healthy',
          'required_permissions' => {
            'whatsapp_business_management' => true,
            'whatsapp_business_messaging' => true
          },
          'waba_access' => true,
          'phone_number_access' => true
        }
      end

      before do
        token_inspection = instance_double(Whatsapp::TokenInspectionService, perform: token_health)
        allow(Whatsapp::TokenInspectionService).to receive(:new)
          .with(access_token: access_token, waba_id: waba_id, phone_number_id: phone_number_id)
          .and_return(token_inspection)
      end

      it 'returns token health metadata' do
        expect(service.perform).to eq(token_health)
      end
    end

    context 'when required permissions are missing' do
      let(:token_health) do
        {
          'status' => 'permission_missing',
          'missing_permissions' => ['whatsapp_business_messaging']
        }
      end

      before do
        token_inspection = instance_double(Whatsapp::TokenInspectionService, perform: token_health)
        allow(Whatsapp::TokenInspectionService).to receive(:new).and_return(token_inspection)
      end

      it 'raises an error' do
        expect { service.perform }.to raise_error(/Token is missing required WhatsApp permissions/)
      end
    end

    context 'when token does not have access to WABA' do
      let(:token_health) do
        {
          'status' => 'waba_access_missing',
          'error' => { 'message' => 'Permissions error' }
        }
      end

      before do
        token_inspection = instance_double(Whatsapp::TokenInspectionService, perform: token_health)
        allow(Whatsapp::TokenInspectionService).to receive(:new).and_return(token_inspection)
      end

      it 'raises an error' do
        expect { service.perform }.to raise_error(/Token does not have access to WABA/)
      end
    end

    context 'when access_token is blank' do
      let(:access_token) { '' }

      it 'raises ArgumentError' do
        expect { service.perform }.to raise_error(ArgumentError, 'Access token is required')
      end
    end

    context 'when waba_id is blank' do
      let(:waba_id) { '' }

      it 'raises ArgumentError' do
        expect { service.perform }.to raise_error(ArgumentError, 'WABA ID is required')
      end
    end
  end
end
