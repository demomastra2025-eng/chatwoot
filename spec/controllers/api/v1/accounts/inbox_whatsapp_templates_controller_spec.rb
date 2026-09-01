require 'rails_helper'

RSpec.describe Api::V1::Accounts::InboxWhatsappTemplatesController, type: :request do
  let(:account) { create(:account, limits: { non_web_inboxes: 10 }) }
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

    it 'sanitizes service failures at the account-facing response boundary' do
      secret = 'template-controller-secret'
      whatsapp_channel.update!(provider_config: whatsapp_channel.provider_config.merge('api_key' => secret))
      allow(management_service).to receive(:create_template).and_return(
        success: false,
        error: "Bearer #{secret}",
        details: { token: secret, diagnostic: "access_token=#{secret}" }
      )

      post "/api/v1/accounts/#{account.id}/inboxes/#{whatsapp_inbox.id}/whatsapp_templates",
           headers: admin.create_new_auth_token,
           params: valid_params,
           as: :json

      expect(response).to have_http_status(:unprocessable_content)
      expect(response.parsed_body).to include(
        'error' => 'Bearer [FILTERED]',
        'details' => { 'diagnostic' => 'access_token=[FILTERED]' }
      )
      expect(response.body).not_to include(secret)
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

    it 'passes uploaded media blob ids through to template management' do
      expect(management_service).to receive(:create_template).with(
        hash_including(
          'header_type' => 'image',
          'sample_media_blob_id' => 'signed-media-blob',
          'sample_media_url' => 'https://app.one-link.kz/media/sample.jpg'
        )
      ).and_return({ success: true, template: {} })

      post "/api/v1/accounts/#{account.id}/inboxes/#{whatsapp_inbox.id}/whatsapp_templates",
           headers: admin.create_new_auth_token,
           params: {
             template: {
               name: 'photo_ready',
               language: 'en',
               category: 'UTILITY',
               header_type: 'image',
               body_text: 'Your photo is ready.',
               sample_media_blob_id: 'signed-media-blob',
               sample_media_url: 'https://app.one-link.kz/media/sample.jpg'
             }
           },
           as: :json

      expect(response).to have_http_status(:created)
    end

    it 'passes authentication preset params through to template management' do
      expect(management_service).to receive(:create_template).with(
        hash_including(
          'category' => 'AUTHENTICATION',
          'add_security_recommendation' => true,
          'code_expiration_minutes' => 10
        )
      ).and_return({ success: true, template: {} })

      post "/api/v1/accounts/#{account.id}/inboxes/#{whatsapp_inbox.id}/whatsapp_templates",
           headers: admin.create_new_auth_token,
           params: {
             template: {
               name: 'login_code',
               language: 'en_US',
               category: 'AUTHENTICATION',
               add_security_recommendation: true,
               code_expiration_minutes: 10
             }
           },
           as: :json

      expect(response).to have_http_status(:created)
    end

    it 'strips unverified Flow creation fields at the API boundary' do
      expect(management_service).to receive(:create_template) do |template_config|
        expect(template_config['buttons']).to eq([{ 'type' => 'FLOW', 'text' => 'Sign up' }])
        { success: true, template: {} }
      end

      post "/api/v1/accounts/#{account.id}/inboxes/#{whatsapp_inbox.id}/whatsapp_templates",
           headers: admin.create_new_auth_token,
           params: {
             template: {
               name: 'signup_flow',
               language: 'en_US',
               category: 'MARKETING',
               body_text: 'Complete your registration.',
               buttons: [
                 {
                   type: 'FLOW',
                   text: 'Sign up',
                   flow_id: '123456789',
                   flow_action: 'navigate',
                   navigate_screen: 'WELCOME_SCREEN'
                 }
               ]
             }
           },
           as: :json

      expect(response).to have_http_status(:created)
    end

    # rubocop:disable RSpec/ExampleLength
    it 'passes structured carousel cards through to template management' do
      expect(management_service).to receive(:create_template).with(
        hash_including(
          'carousel_cards' => [
            hash_including(
              'header_type' => 'image',
              'sample_media_url' => 'https://example.com/card-1.jpg',
              'sample_media_blob_id' => 'signed-card-1-blob',
              'body_text' => 'Product one',
              'buttons' => [
                hash_including('type' => 'QUICK_REPLY', 'text' => 'Choose')
              ]
            ),
            hash_including(
              'header_type' => 'image',
              'sample_media_url' => 'https://example.com/card-2.jpg',
              'body_text' => 'Product two'
            )
          ]
        )
      ).and_return({ success: true, template: {} })

      post "/api/v1/accounts/#{account.id}/inboxes/#{whatsapp_inbox.id}/whatsapp_templates",
           headers: admin.create_new_auth_token,
           params: {
             template: {
               name: 'product_carousel',
               language: 'en_US',
               category: 'MARKETING',
               body_text: 'Choose a product.',
               carousel_cards: [
                 {
                   header_type: 'image',
                   sample_media_url: 'https://example.com/card-1.jpg',
                   sample_media_blob_id: 'signed-card-1-blob',
                   body_text: 'Product one',
                   body_examples: {},
                   buttons: [
                     { type: 'QUICK_REPLY', text: 'Choose' }
                   ]
                 },
                 {
                   header_type: 'image',
                   sample_media_url: 'https://example.com/card-2.jpg',
                   body_text: 'Product two',
                   body_examples: {},
                   buttons: [{ type: 'QUICK_REPLY', text: 'Choose' }]
                 }
               ]
             }
           },
           as: :json

      expect(response).to have_http_status(:created)
    end
    # rubocop:enable RSpec/ExampleLength
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

  describe 'PATCH /api/v1/accounts/{account.id}/inboxes/{inbox.id}/whatsapp_templates/{template_name}/visibility' do
    before do
      whatsapp_channel.update!(
        message_templates: [
          {
            'name' => 'automation_only',
            'language' => 'en',
            'status' => 'APPROVED',
            'components' => [{ 'type' => 'BODY', 'text' => 'Automated message' }]
          }
        ]
      )
    end

    it 'stores picker visibility and returns the updated inbox' do
      patch "/api/v1/accounts/#{account.id}/inboxes/#{whatsapp_inbox.id}/whatsapp_templates/automation_only/visibility",
            headers: admin.create_new_auth_token,
            params: { visible_in_conversation_picker: false },
            as: :json

      expect(response).to have_http_status(:ok)
      expect(response.parsed_body.dig('message_templates', 0, 'visible_in_conversation_picker')).to be(false)
      expect(whatsapp_channel.reload.message_templates.first['visible_in_conversation_picker']).to be(false)
    end

    it 'returns not found for a missing template' do
      patch "/api/v1/accounts/#{account.id}/inboxes/#{whatsapp_inbox.id}/whatsapp_templates/missing/visibility",
            headers: admin.create_new_auth_token,
            params: { visible_in_conversation_picker: false },
            as: :json

      expect(response).to have_http_status(:not_found)
    end
  end
end
