# frozen_string_literal: true

require 'rails_helper'

# A clinic cannot CREATE an inbox of a channel it does not have (the platform hides it, the clinic's exception hides
# it, or the clinic lacks the feature flag). Existing inboxes keep working: only creation is guarded.
RSpec.describe 'Channel availability guard', type: :request do
  let(:account) { create(:account) }
  let(:admin) { create(:user, account: account, role: :administrator) }
  let(:agent) { create(:user, account: account, role: :agent) }
  let(:headers) { admin.create_new_auth_token }
  let(:base_path) { "/api/v1/accounts/#{account.id}" }
  let(:channel_flags) { %w[channel_website channel_facebook channel_instagram channel_tiktok channel_twitter channel_email channel_voice] }

  before { account.enable_features!(*channel_flags) }

  def create_inbox(channel, auth_headers = headers)
    post "#{base_path}/inboxes", headers: auth_headers, params: { name: 'Guarded inbox', channel: channel }, as: :json
  end

  def expect_not_available(key)
    expect(response).to have_http_status(:forbidden)
    expect(response.parsed_body).to include(
      'code' => 'channel_not_available',
      'channel' => key,
      'error' => Channels::Catalog.unavailable_message(key)
    )
  end

  describe 'POST /inboxes' do
    let(:hidden_by_default) do
      {
        'api' => { type: 'api', webhook_url: 'http://test.com' },
        'sms' => { type: 'sms', phone_number: '+123456789', provider_config: { test: 'test' } },
        'line' => { type: 'line', line_channel_id: 'id', line_channel_secret: 'secret', line_channel_token: 'token' },
        'weixin' => { type: 'weixin' },
        'vk_community' => { type: 'vk_community' }
      }
    end

    it 'refuses every channel the platform hides by default, with a Russian message, and creates nothing' do
      hidden_by_default.each do |key, channel|
        expect { create_inbox(channel) }.not_to change(Inbox, :count)

        expect_not_available(key)
      end
      expect(response.parsed_body['error']).to start_with('Канал «')
    end

    it 'lets a shown channel through' do
      create_inbox(type: 'web_widget', website_url: 'test.com')

      expect(response).to have_http_status(:success)
    end

    it 'refuses a channel the platform switches off and lets it through again when the platform switches it on' do
      change_platform_channel_visibility('website' => 'hidden')
      create_inbox(type: 'web_widget', website_url: 'test.com')
      expect_not_available('website')

      change_platform_channel_visibility('website' => 'shown')
      create_inbox(type: 'web_widget', website_url: 'test.com')
      expect(response).to have_http_status(:success)
    end

    it 'lets a hidden channel through when the platform shows it' do
      change_platform_channel_visibility('api' => 'shown')

      expect { create_inbox(type: 'api', webhook_url: 'http://test.com') }.to change(Inbox, :count).by(1)

      expect(response).to have_http_status(:success)
    end

    it 'lets a hidden channel through for the one clinic that has an exception' do
      other_account = create(:account)
      other_admin = create(:user, account: other_account, role: :administrator)
      show_channels_for(account, 'api')

      create_inbox(type: 'api', webhook_url: 'http://test.com')
      expect(response).to have_http_status(:success)

      post "/api/v1/accounts/#{other_account.id}/inboxes",
           headers: other_admin.create_new_auth_token,
           params: { name: 'Guarded inbox', channel: { type: 'api', webhook_url: 'http://test.com' } }, as: :json
      expect_not_available('api')
    end

    it 'refuses a shown channel that the clinic exception hides' do
      hide_channels_for(account, 'website')

      create_inbox(type: 'web_widget', website_url: 'test.com')

      expect_not_available('website')
    end

    it 'refuses a shown channel when the clinic lacks its feature flag, whatever the exception says' do
      account.disable_features!('channel_website')
      show_channels_for(account, 'website')

      create_inbox(type: 'web_widget', website_url: 'test.com')

      expect_not_available('website')
    end

    it 'asks the administrator check first: an agent gets the usual 401, not a channel message' do
      create_inbox({ type: 'api', webhook_url: 'http://test.com' }, agent.create_new_auth_token)

      expect(response).to have_http_status(:unauthorized)
    end

    it 'leaves a type the endpoint does not know to the usual validation' do
      create_inbox(type: 'linkedin_personal')

      expect(response).to have_http_status(:unprocessable_content)
    end

    it 'guards each provider choice as its own channel' do
      change_platform_channel_visibility(
        'whatsapp_cloud' => 'hidden', 'whatsapp_web' => 'hidden', 'telegram_bot' => 'hidden', 'telegram_personal' => 'hidden'
      )

      {
        'whatsapp_cloud' => { type: 'whatsapp', provider: 'whatsapp_cloud', phone_number: '+77066318623' },
        'whatsapp_web' => { type: 'whatsapp_web', phone_number: '+77066318623' },
        'telegram_bot' => { type: 'telegram', bot_token: '123:abc' },
        'telegram_personal' => { type: 'telegram_personal', api_id: 1, api_hash: 'hash', phone_number: '+77066318623' }
      }.each do |key, channel|
        expect { create_inbox(channel) }.not_to change(Inbox, :count)

        expect_not_available(key)
      end
    end

    it 'folds the legacy 360dialog provider of WhatsApp into the Cloud API switch' do
      change_platform_channel_visibility('whatsapp_cloud' => 'hidden')

      create_inbox(type: 'whatsapp', provider: 'default', phone_number: '+77066318623')

      expect_not_available('whatsapp_cloud')
    end

    it 'guards the voice inbox' do
      change_platform_channel_visibility('voice' => 'hidden')

      expect { create_inbox(type: 'voice', phone_number: '+17715550123', provider: 'sipuni') }.not_to change(Inbox, :count)

      expect_not_available('voice')
    end

    it 'does not touch the inboxes that exist: they can still be updated and reset while their channel is hidden' do
      api_channel = create(:channel_api, account: account)
      api_inbox = api_channel.inbox

      patch "#{base_path}/inboxes/#{api_inbox.id}", headers: headers, params: { name: 'Renamed API inbox' }, as: :json
      expect(response).to have_http_status(:success)
      expect(api_inbox.reload.name).to eq('Renamed API inbox')

      post "#{base_path}/inboxes/#{api_inbox.id}/reset_secret", headers: headers, as: :json
      expect(response).to have_http_status(:success)

      get "#{base_path}/inboxes", headers: headers, as: :json
      expect(response.parsed_body['payload'].pluck('id')).to include(api_inbox.id)
    end
  end

  describe 'POST /channels/twilio_channel' do
    let(:twilio_client) { instance_double(Twilio::REST::Client) }
    let(:message_double) { double }
    let(:sms_params) do
      { twilio_channel: { account_sid: 'sid', auth_token: 'token', phone_number: '+1234567890', name: 'SMS Channel', medium: 'sms' } }
    end
    let(:whatsapp_params) do
      { twilio_channel: { account_sid: 'sid', auth_token: 'token', phone_number: '+1234567890', name: 'WhatsApp Channel', medium: 'whatsapp' } }
    end

    before do
      allow(Twilio::REST::Client).to receive(:new).and_return(twilio_client)
      allow(Twilio::WebhookSetupService).to receive(:new).and_return(instance_double(Twilio::WebhookSetupService, perform: true))
      allow(twilio_client).to receive(:messages).and_return(message_double)
      allow(message_double).to receive(:list).and_return([])
    end

    it 'refuses SMS while it is hidden and never calls Twilio' do
      expect { post "#{base_path}/channels/twilio_channel", params: sms_params, headers: headers }.not_to change(Inbox, :count)

      expect_not_available('sms')
      expect(Twilio::REST::Client).not_to have_received(:new)
    end

    it 'treats WhatsApp through Twilio as its own channel: it works while SMS is hidden' do
      post "#{base_path}/channels/twilio_channel", params: whatsapp_params, headers: headers

      expect(response).to have_http_status(:success)
    end

    it 'refuses WhatsApp through Twilio when the platform hides it, SMS stays as it is' do
      change_platform_channel_visibility('whatsapp_twilio' => 'hidden', 'sms' => 'shown')

      post "#{base_path}/channels/twilio_channel", params: whatsapp_params, headers: headers
      expect_not_available('whatsapp_twilio')

      post "#{base_path}/channels/twilio_channel", params: sms_params, headers: headers
      expect(response).to have_http_status(:success)
    end

    it 'lets SMS through for the clinic that has an exception' do
      show_channels_for(account, 'sms')

      post "#{base_path}/channels/twilio_channel", params: sms_params, headers: headers

      expect(response).to have_http_status(:success)
    end
  end

  describe 'Facebook pages' do
    before { change_platform_channel_visibility('facebook' => 'hidden') }

    it 'refuses to list the pages and to register one while Facebook is hidden' do
      post "#{base_path}/callbacks/facebook_pages", headers: headers, params: { omniauth_token: 'token' }, as: :json
      expect_not_available('facebook')

      expect do
        post "#{base_path}/callbacks/register_facebook_page",
             headers: headers, params: { page_id: '123', inbox_name: 'Page', user_access_token: 'u', page_access_token: 'p' }, as: :json
      end.not_to change(Inbox, :count)
      expect_not_available('facebook')
    end

    it 'does not guard the reauthorization of an existing page' do
      post "#{base_path}/callbacks/reauthorize_page", headers: headers, params: { omniauth_token: 'token', inbox_id: 1 }, as: :json

      expect(response).not_to have_http_status(:forbidden)
    end
  end

  describe 'Instagram authorization' do
    it 'refuses to start a new connection while Instagram is hidden' do
      change_platform_channel_visibility('instagram' => 'hidden')

      post "#{base_path}/instagram/authorization", headers: headers, as: :json

      expect_not_available('instagram')
    end

    it 'still lets an existing inbox be reauthorized while Instagram is hidden' do
      change_platform_channel_visibility('instagram' => 'hidden')
      instagram_inbox = create(:channel_instagram, account: account).inbox

      post "#{base_path}/instagram/authorization", headers: headers, params: { inbox_id: instagram_inbox.id }, as: :json

      expect(response).to have_http_status(:success)
      expect(response.parsed_body['success']).to be(true)
    end
  end

  describe 'Twitter authorization' do
    it 'refuses to start while Twitter is hidden (the default)' do
      post "#{base_path}/twitter/authorization", headers: headers, as: :json

      expect_not_available('twitter')
    end
  end

  describe 'WhatsApp embedded signup' do
    let(:signup_params) { { code: 'auth_code', business_id: 'business', waba_id: 'waba', phone_number_id: 'phone' } }

    before { change_platform_channel_visibility('whatsapp_cloud' => 'hidden') }

    it 'refuses a new connection while WhatsApp Cloud API is hidden, with the error_code the signup screen reads' do
      allow(Whatsapp::EmbeddedSignupService).to receive(:new)

      post "#{base_path}/whatsapp/authorization", headers: headers, params: signup_params, as: :json

      expect(response).to have_http_status(:forbidden)
      expect(response.parsed_body).to include(
        'code' => 'channel_not_available', 'error_code' => 'channel_not_available', 'channel' => 'whatsapp_cloud',
        'error' => Channels::Catalog.unavailable_message('whatsapp_cloud')
      )
      expect(Whatsapp::EmbeddedSignupService).not_to have_received(:new)
    end

    it 'does not guard the reauthorization of an existing inbox' do
      channel = create(:channel_whatsapp, account: account, provider: 'whatsapp_cloud', validate_provider_config: false, sync_templates: false)
      allow(Whatsapp::EmbeddedSignupService).to receive(:new).and_raise(StandardError, 'Token exchange failed')

      post "#{base_path}/whatsapp/authorization", headers: headers, params: signup_params.merge(inbox_id: channel.inbox.id), as: :json

      expect(response.parsed_body['error_code']).not_to eq('channel_not_available')
      expect(response).not_to have_http_status(:forbidden)
    end
  end

  describe 'Telephony virtual PBX channels' do
    let(:payload) do
      {
        provider_kind: 'sipuni', channel_name: 'Sipuni external line', display_phone_number: '+17715550999',
        provider_account_number: '056124100014', ingress_number: '056124100014',
        connection: { host: 'ats01.kz.sipuni.com', port: 5060, transport: 'udp', username: '056124100014', password: 'secret' }
      }
    end

    before { change_platform_channel_visibility('voice' => 'hidden') }

    it 'refuses to create a channel while voice is hidden, in the telephony error shape' do
      expect do
        post "#{base_path}/telephony/virtual_pbx_channels", headers: headers, params: payload, as: :json
      end.not_to change(Inbox, :count)

      expect(response).to have_http_status(:forbidden)
      expect(response.parsed_body).to include(
        'code' => 'CHANNEL_NOT_AVAILABLE', 'error' => Channels::Catalog.unavailable_message('voice')
      )
    end

    it 'does not guard the templates or an existing channel' do
      voice_channel = create(:channel_voice, :sipuni, account: account, phone_number: '+17715550123')

      get "#{base_path}/telephony/virtual_pbx_channels/templates", headers: headers
      expect(response).to have_http_status(:ok)

      get "#{base_path}/telephony/virtual_pbx_channels/#{voice_channel.inbox.id}", headers: headers
      expect(response).to have_http_status(:ok)
    end
  end

  describe 'the account payload of the operator app' do
    it 'lists the available channels next to the features' do
      get base_path, headers: headers, as: :json

      expect(response).to have_http_status(:success)
      expect(response.parsed_body['available_channels']).to eq(Accounts::AvailableChannels.for(account))
      expect(response.parsed_body['available_channels']).to include('website', 'whatsapp_cloud', 'telegram_bot')
      expect(response.parsed_body['available_channels']).not_to include('api', 'sms', 'tiktok')
    end

    it 'follows the platform switch and the clinic exception' do
      change_platform_channel_visibility('api' => 'shown', 'facebook' => 'hidden')
      hide_channels_for(account, 'website')

      get base_path, headers: headers, as: :json

      expect(response.parsed_body['available_channels']).to include('api')
      expect(response.parsed_body['available_channels']).not_to include('facebook', 'website')
    end
  end
end
