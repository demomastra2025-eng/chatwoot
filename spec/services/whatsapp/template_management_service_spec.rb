require 'rails_helper'

RSpec.describe Whatsapp::TemplateManagementService do
  include ActiveJob::TestHelper

  let(:whatsapp_channel) do
    create(
      :channel_whatsapp,
      provider: 'whatsapp_cloud',
      sync_templates: false,
      validate_provider_config: false
    )
  end
  let(:provider_service) { instance_double(Whatsapp::Providers::WhatsappCloudService) }
  let(:request_builder) { instance_double(Whatsapp::TemplateRequestBuilderService) }
  let(:request_body) do
    {
      name: 'order_update',
      language: 'en',
      category: 'UTILITY',
      components: [
        { type: 'BODY', text: 'Order {{1}} updated', example: { body_text: [['123']] } }
      ]
    }
  end

  before do
    allow(whatsapp_channel).to receive(:provider_service).and_return(provider_service)
    allow(Whatsapp::TemplateRequestBuilderService).to receive(:new).and_return(request_builder)
    allow(request_builder).to receive(:call).and_return(request_body)
  end

  describe '#create_template' do
    it 'updates the local cache and schedules a sync after success' do
      response = instance_double(
        HTTParty::Response,
        success?: true,
        parsed_response: { 'id' => 'template-id', 'status' => 'PENDING' }
      )

      allow(provider_service).to receive(:create_template).with(request_body).and_return(response)

      result = nil
      expect do
        result = described_class.new(whatsapp_channel: whatsapp_channel).create_template({})
      end.to have_enqueued_job(Channels::Whatsapp::TemplatesSyncJob).with(whatsapp_channel)

      expect(result[:success]).to be(true)
      expect(result[:template]['name']).to eq('order_update')
      expect(whatsapp_channel.reload.message_templates.first['status']).to eq('PENDING')
      expect(whatsapp_channel.message_templates.first['components'].first['text']).to eq('Order {{1}} updated')
    end

    it 'recovers the local cache when provider reports that the template already exists' do
      provider_error = {
        'error' => {
          'message' => 'Template name already exists for this language',
          'code' => 100
        }
      }
      response = instance_double(
        HTTParty::Response,
        success?: false,
        body: provider_error.to_json
      )
      remote_template = {
        'id' => 'remote-template-id',
        'name' => 'order_update',
        'language' => 'en',
        'status' => 'APPROVED',
        'category' => 'UTILITY',
        'components' => [{ 'type' => 'BODY', 'text' => 'Order {{1}} updated' }]
      }

      allow(provider_service).to receive(:create_template).with(request_body).and_return(response)
      allow(provider_service).to receive(:fetch_templates).and_return([remote_template])

      result = nil
      expect do
        result = described_class.new(whatsapp_channel: whatsapp_channel).create_template({})
      end.to have_enqueued_job(Channels::Whatsapp::TemplatesSyncJob).with(whatsapp_channel)

      expect(result[:success]).to be(true)
      expect(result[:recovered]).to be(true)
      expect(result[:template]['id']).to eq('remote-template-id')
      expect(whatsapp_channel.reload.message_templates.first['name']).to eq('order_update')
      expect(whatsapp_channel.message_templates.first['status']).to eq('APPROVED')
    end

    it 'recovers the local cache when provider times out after creating the template' do
      remote_template = {
        'id' => 'remote-template-id',
        'name' => 'order_update',
        'language' => 'en',
        'status' => 'PENDING',
        'category' => 'UTILITY',
        'components' => [{ 'type' => 'BODY', 'text' => 'Order {{1}} updated' }]
      }

      allow(provider_service).to receive(:create_template).with(request_body).and_raise(Net::ReadTimeout)
      allow(provider_service).to receive(:fetch_templates).and_return([remote_template])

      result = described_class.new(whatsapp_channel: whatsapp_channel).create_template({})

      expect(result[:success]).to be(true)
      expect(result[:recovered]).to be(true)
      expect(whatsapp_channel.reload.message_templates.first['id']).to eq('remote-template-id')
    end

    it 'sanitizes provider failure payloads before returning them' do
      secret = 'template-provider-secret'
      whatsapp_channel.update!(provider_config: whatsapp_channel.provider_config.merge('api_key' => secret))
      response = instance_double(
        HTTParty::Response,
        success?: false,
        body: { error: { message: "access_token=#{secret}", code: 190, error_user_title: "Bearer #{secret}" } }.to_json
      )
      allow(provider_service).to receive(:create_template).with(request_body).and_return(response)

      result = described_class.new(whatsapp_channel: whatsapp_channel).create_template({})

      expect(result).to include(success: false)
      expect(result[:error]).to include('[FILTERED]')
      expect(result[:details]).to include(code: 190, title: 'Bearer [FILTERED]')
      expect(result[:response_body]).to include('[FILTERED]')
      expect(result.to_s).not_to include(secret)
    end

    it 'returns a generic account-facing error and sanitizes logs for provider exceptions' do
      secret = 'template-exception-secret'
      whatsapp_channel.update!(provider_config: whatsapp_channel.provider_config.merge('api_key' => secret))
      allow(Rails.logger).to receive(:error)
      allow(provider_service).to receive(:create_template)
        .with(request_body)
        .and_raise(StandardError, "request failed access_token=#{secret}")

      result = described_class.new(whatsapp_channel: whatsapp_channel).create_template({})

      expect(result).to include(success: false, error: 'Template operation failed. Please try again.')
      expect(result.to_s).not_to include(secret)
      expect(Rails.logger).to have_received(:error).with(a_string_including('[FILTERED]'))
      expect(Rails.logger).not_to have_received(:error).with(a_string_including(secret))
    end
  end

  describe '#delete_template' do
    it 'removes the template from local cache and schedules a sync after success' do
      response = instance_double(HTTParty::Response, success?: true, body: '', parsed_response: {})

      allow(provider_service).to receive(:delete_template).with('test_no_params_template').and_return(response)

      result = nil
      expect do
        result = described_class.new(whatsapp_channel: whatsapp_channel).delete_template('test_no_params_template')
      end.to have_enqueued_job(Channels::Whatsapp::TemplatesSyncJob).with(whatsapp_channel)

      expect(result[:success]).to be(true)
      expect(
        whatsapp_channel.reload.message_templates.map { |template| template['name'] }
      ).not_to include('test_no_params_template')
    end
  end
end
