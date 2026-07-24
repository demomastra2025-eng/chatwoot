require 'rails_helper'

describe Whatsapp::PhoneInfoService do
  let(:waba_id) { 'test_waba_id' }
  let(:phone_number_id) { 'test_phone_number_id' }
  let(:access_token) { 'test_access_token' }
  let(:service) { described_class.new(waba_id, phone_number_id, access_token) }
  let(:api_client) { instance_double(Whatsapp::FacebookApiClient) }

  before do
    allow(Whatsapp::FacebookApiClient).to receive(:new).with(access_token).and_return(api_client)
  end

  describe '#perform' do
    let(:phone_response) do
      {
        'data' => [
          {
            'id' => phone_number_id,
            'display_phone_number' => '1234567890',
            'verified_name' => 'Test Business',
            'code_verification_status' => 'VERIFIED'
          }
        ]
      }
    end

    context 'when all parameters are valid' do
      before do
        allow(api_client).to receive(:fetch_phone_numbers).with(waba_id).and_return(phone_response)
      end

      it 'returns formatted phone info' do
        result = service.perform
        expect(result).to eq({
                               phone_number_id: phone_number_id,
                               phone_number: '+1234567890',
                               verified: true,
                               business_name: 'Test Business',
                               calling_capable: false,
                               calling_capabilities: []
                             })
      end
    end

    context 'when phone number has WhatsApp Calling capability' do
      let(:phone_response) do
        {
          'data' => [
            {
              'id' => phone_number_id,
              'display_phone_number' => '1234567890',
              'verified_name' => 'Test Business',
              'code_verification_status' => 'VERIFIED',
              'capabilities' => ['CALLING']
            }
          ]
        }
      end

      before do
        allow(api_client).to receive(:fetch_phone_numbers).with(waba_id).and_return(phone_response)
      end

      it 'marks the phone number as calling capable' do
        result = service.perform

        expect(result[:calling_capable]).to be true
        expect(result[:calling_capabilities]).to include('CALLING')
      end
    end

    context 'when phone number is on a later Meta page' do
      let(:first_page_response) do
        {
          'data' => [{ 'id' => 'other_phone_id' }],
          'paging' => {
            'next' => 'https://graph.facebook.com/v22.0/test_waba_id/phone_numbers?after=cursor_1',
            'cursors' => { 'after' => 'cursor_1' }
          }
        }
      end
      let(:second_page_response) do
        {
          'data' => [
            {
              'id' => phone_number_id,
              'display_phone_number' => '1234567890',
              'verified_name' => 'Paged Business',
              'code_verification_status' => 'VERIFIED'
            }
          ]
        }
      end

      it 'paginates until it finds the requested phone number' do
        expect(api_client).to receive(:fetch_phone_numbers).with(waba_id).and_return(first_page_response)
        expect(api_client).to receive(:fetch_phone_numbers).with(waba_id, after: 'cursor_1').and_return(second_page_response)

        result = service.perform
        expect(result[:phone_number_id]).to eq(phone_number_id)
        expect(result[:business_name]).to eq('Paged Business')
      end
    end

    context 'when phone_number_id is not provided' do
      let(:phone_number_id) { nil }

      it 'raises an error instead of silently choosing the first available phone number' do
        expect(api_client).not_to receive(:fetch_phone_numbers)

        expect { service.perform }.to raise_error(ArgumentError, 'Phone number ID is required')
      end
    end

    context 'when resolving a standard number from the official WABA-only event' do
      let(:phone_number_id) { nil }
      let(:service) do
        described_class.new(waba_id, nil, access_token, allow_unambiguous_selection: true)
      end
      let(:phone_response) do
        {
          'data' => [
            {
              'id' => 'only-phone',
              'display_phone_number' => '77010000001',
              'verified_name' => 'Cloud Business',
              'code_verification_status' => 'VERIFIED'
            }
          ]
        }
      end

      it 'selects the only accessible phone number' do
        expect(api_client).to receive(:fetch_phone_numbers).with(waba_id).and_return(phone_response)

        expect(service.perform).to include(phone_number_id: 'only-phone')
      end

      it 'fails closed when several phone numbers are accessible' do
        phone_response['data'] << phone_response['data'].first.merge('id' => 'second-phone')
        allow(api_client).to receive(:fetch_phone_numbers).with(waba_id).and_return(phone_response)

        expect { service.perform }.to raise_error(/Multiple eligible phone numbers/)
      end
    end

    context 'when specific phone_number_id is not found' do
      let(:phone_number_id) { 'different_id' }
      let(:phone_response) do
        {
          'data' => [
            {
              'id' => 'available_phone_id',
              'display_phone_number' => '9876543210',
              'verified_name' => 'Different Business',
              'code_verification_status' => 'VERIFIED'
            }
          ]
        }
      end

      before do
        allow(api_client).to receive(:fetch_phone_numbers).with(waba_id).and_return(phone_response)
      end

      it 'raises an error instead of creating the inbox for a different number' do
        expect { service.perform }
          .to raise_error(/Phone number different_id is not available for WABA test_waba_id/)
      end
    end

    context 'when resolving a coexistence number from the official WABA-only event' do
      let(:phone_number_id) { nil }
      let(:service) { described_class.new(waba_id, nil, access_token, coexistence: true) }
      let(:phone_response) do
        {
          'data' => [
            {
              'id' => 'cloud-only',
              'display_phone_number' => '77010000001',
              'platform_type' => 'CLOUD_API',
              'is_on_biz_app' => false
            },
            {
              'id' => 'business-app-phone',
              'display_phone_number' => '77010000002',
              'verified_name' => 'Business App',
              'code_verification_status' => 'VERIFIED',
              'platform_type' => 'CLOUD_API',
              'is_on_biz_app' => true
            }
          ]
        }
      end

      it 'selects only the phone Meta marks as connected to the Business app' do
        expect(api_client).to receive(:fetch_phone_numbers)
          .with(waba_id, after: nil, fields: described_class::PHONE_NUMBER_FIELDS)
          .and_return(phone_response)

        expect(service.perform).to include(
          phone_number_id: 'business-app-phone',
          is_on_biz_app: true,
          platform_type: 'CLOUD_API'
        )
      end
    end

    context 'when no phone numbers are available' do
      let(:phone_response) { { 'data' => [] } }

      before do
        allow(api_client).to receive(:fetch_phone_numbers).with(waba_id).and_return(phone_response)
      end

      it 'raises an error' do
        expect { service.perform }.to raise_error(/Phone number test_phone_number_id is not available for WABA test_waba_id/)
      end
    end

    context 'when waba_id is blank' do
      let(:waba_id) { '' }

      it 'raises ArgumentError' do
        expect { service.perform }.to raise_error(ArgumentError, 'WABA ID is required')
      end
    end

    context 'when access_token is blank' do
      let(:access_token) { '' }

      it 'raises ArgumentError' do
        expect { service.perform }.to raise_error(ArgumentError, 'Access token is required')
      end
    end

    context 'when phone number has special characters' do
      let(:phone_response) do
        {
          'data' => [
            {
              'id' => phone_number_id,
              'display_phone_number' => '+1 (234) 567-8900',
              'verified_name' => 'Test Business',
              'code_verification_status' => 'VERIFIED'
            }
          ]
        }
      end

      before do
        allow(api_client).to receive(:fetch_phone_numbers).with(waba_id).and_return(phone_response)
      end

      it 'sanitizes the phone number' do
        result = service.perform
        expect(result[:phone_number]).to eq('+12345678900')
      end
    end
  end
end
