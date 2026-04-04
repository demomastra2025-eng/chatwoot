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
