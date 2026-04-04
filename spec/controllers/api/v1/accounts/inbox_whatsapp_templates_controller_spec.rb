require 'rails_helper'

RSpec.describe Api::V1::Accounts::InboxWhatsappTemplatesController, type: :request do
  let(:account) { create(:account) }
  let(:admin) { create(:user, account: account, role: :administrator) }
  let(:agent) { create(:user, account: account, role: :agent) }
  let(:whatsapp_channel) do
    create(
      :channel_whatsapp,
      account: account,
      provider: 'whatsapp_cloud',
      sync_templates: false,
      validate_provider_config: false
    )
  end
  let(:whatsapp_inbox) { whatsapp_channel.inbox }
  let(:web_widget_inbox) { create(:inbox, account: account) }
  let(:management_service) { instance_double(Whatsapp::TemplateManagementService) }

  before do
    create(:inbox_member, user: agent, inbox: whatsapp_inbox)
    allow(Whatsapp::TemplateManagementService).to receive(:new).and_return(management_service)
  end

  describe 'POST /api/v1/accounts/{account.id}/inboxes/{inbox.id}/whatsapp_templates' do
    let(:valid_params) do
      {
        template: {
          name: 'order_update',
          language: 'en',
          category: 'UTILITY',
          header_type: 'none',
          body_text: 'Hello {{1}}',
          body_examples: { '1' => 'Alex' }
        }
      }
    end
    let(:phone_number_button) do
      {
        type: 'PHONE_NUMBER',
        text: 'Call support',
        phone_number: '+18005551234'
      }
    end
    let(:phone_number_template_params) do
      {
        template: {
          name: 'delivery_failed',
          language: 'en',
          category: 'UTILITY',
          header_type: 'none',
          body_text: 'Call us if you need help.',
          buttons: [phone_number_button]
        }
      }
    end
    let(:phone_number_template) do
      {
        'name' => 'delivery_failed',
        'language' => 'en',
        'status' => 'PENDING',
        'category' => 'UTILITY',
        'components' => [
          { 'type' => 'BODY', 'text' => 'Call us if you need help.' },
          {
            'type' => 'BUTTONS',
            'buttons' => [
              phone_number_button.deep_stringify_keys
            ]
          }
        ]
      }
    end

    it 'returns unauthorized for unauthenticated users' do
      post "/api/v1/accounts/#{account.id}/inboxes/#{whatsapp_inbox.id}/whatsapp_templates",
           params: valid_params,
           as: :json

      expect(response).to have_http_status(:unauthorized)
    end

    it 'returns unauthorized for non-admin users' do
      post "/api/v1/accounts/#{account.id}/inboxes/#{whatsapp_inbox.id}/whatsapp_templates",
           headers: agent.create_new_auth_token,
           params: valid_params,
           as: :json

      expect(response).to have_http_status(:unauthorized)
    end

    it 'returns bad request for non-cloud inboxes' do
      post "/api/v1/accounts/#{account.id}/inboxes/#{web_widget_inbox.id}/whatsapp_templates",
           headers: admin.create_new_auth_token,
           params: valid_params,
           as: :json

      expect(response).to have_http_status(:bad_request)
      expect(response.parsed_body['error']).to eq('WhatsApp template management is only available for WhatsApp Cloud channels')
    end

    it 'returns the updated inbox payload after create' do
      whatsapp_channel.update!(
        message_templates: [
          {
            'name' => 'order_update',
            'language' => 'en',
            'status' => 'PENDING',
            'category' => 'UTILITY',
            'components' => [{ 'type' => 'BODY', 'text' => 'Hello {{1}}' }]
          }
        ]
      )

      allow(management_service).to receive(:create_template).and_return({
                                                                          success: true,
                                                                          template: whatsapp_channel.message_templates.first
                                                                        })

      post "/api/v1/accounts/#{account.id}/inboxes/#{whatsapp_inbox.id}/whatsapp_templates",
           headers: admin.create_new_auth_token,
           params: valid_params,
           as: :json

      expect(response).to have_http_status(:created)
      expect(response.parsed_body['id']).to eq(whatsapp_inbox.id)
      expect(response.parsed_body['message_templates'].first['name']).to eq('order_update')
    end

    it 'passes phone number button params through to template management' do
      whatsapp_channel.update!(message_templates: [phone_number_template])

      expect(management_service).to receive(:create_template).with(
        hash_including(
          'buttons' => [
            hash_including(
              'type' => phone_number_button[:type],
              'text' => phone_number_button[:text],
              'phone_number' => phone_number_button[:phone_number]
            )
          ]
        )
      ).and_return({
                     success: true,
                     template: whatsapp_channel.message_templates.first
                   })

      post "/api/v1/accounts/#{account.id}/inboxes/#{whatsapp_inbox.id}/whatsapp_templates",
           headers: admin.create_new_auth_token,
           params: phone_number_template_params,
           as: :json

      expect(response).to have_http_status(:created)
    end
  end

  describe 'DELETE /api/v1/accounts/{account.id}/inboxes/{inbox.id}/whatsapp_templates/{template_name}' do
    it 'blocks deletion of CSAT-managed templates' do
      whatsapp_inbox.update!(csat_config: { 'template' => { 'name' => 'customer_satisfaction_survey_1' } })

      delete "/api/v1/accounts/#{account.id}/inboxes/#{whatsapp_inbox.id}/whatsapp_templates/customer_satisfaction_survey_1",
             headers: admin.create_new_auth_token,
             as: :json

      expect(response).to have_http_status(:unprocessable_content)
      expect(response.parsed_body['error']).to eq('CSAT-managed templates cannot be deleted from the template library')
    end

    it 'returns the updated inbox payload after delete' do
      whatsapp_channel.update!(
        message_templates: [
          {
            'name' => 'keep_template',
            'language' => 'en',
            'status' => 'APPROVED',
            'category' => 'UTILITY',
            'components' => [{ 'type' => 'BODY', 'text' => 'Keep me' }]
          }
        ]
      )

      allow(management_service).to receive(:delete_template).and_return({ success: true })

      delete "/api/v1/accounts/#{account.id}/inboxes/#{whatsapp_inbox.id}/whatsapp_templates/remove_me",
             headers: admin.create_new_auth_token,
             as: :json

      expect(response).to have_http_status(:ok)
      expect(response.parsed_body['message_templates'].first['name']).to eq('keep_template')
    end
  end
end
