require 'rails_helper'

RSpec.describe 'Microsoft::CallbacksController', type: :request do
  let(:account) { create(:account) }
  let(:base_url) { ENV.fetch('FRONTEND_URL', 'http://localhost:3000') }
  let(:code) { SecureRandom.hex(10) }
  let(:email) { Faker::Internet.email }
  let(:state) { account.to_sgid(expires_in: 15.minutes).to_s }

  describe 'GET /microsoft/callback' do
    let(:response_body_success) do
      { id_token: JWT.encode({ email: email, name: 'test' }, false), access_token: SecureRandom.hex(10), token_type: 'Bearer',
        refresh_token: SecureRandom.hex(10) }
    end

    let(:response_body_success_without_name) do
      { id_token: JWT.encode({ email: email }, false), access_token: SecureRandom.hex(10), token_type: 'Bearer',
        refresh_token: SecureRandom.hex(10) }
    end

    it 'creates inboxes if authentication is successful' do
      stub_request(:post, 'https://login.microsoftonline.com/common/oauth2/v2.0/token')
        .with(body: { 'code' => code, 'grant_type' => 'authorization_code',
                      'redirect_uri' => "#{base_url}/microsoft/callback" })
        .to_return(status: 200, body: response_body_success.to_json, headers: { 'Content-Type' => 'application/json' })

      get microsoft_callback_url, params: { code: code, state: state }

      expect(response).to redirect_to app_email_inbox_agents_url(account_id: account.id, inbox_id: account.inboxes.last.id)
      expect(account.inboxes.count).to be 1
      inbox = account.inboxes.last
      expect(inbox.name).to eq 'test'
      expect(inbox.channel.reload.provider_config.keys).to include('access_token', 'refresh_token', 'expires_on')
      expect(inbox.channel.reload.provider_config['access_token']).to eq response_body_success[:access_token]
      expect(inbox.channel.imap_address).to eq 'outlook.office365.com'
    end

    it 'creates updates inbox channel config if inbox exists and authentication is successful' do
      inbox = create(:channel_email, account: account, email: email)&.inbox
      expect(inbox.channel.provider_config).to eq({})

      stub_request(:post, 'https://login.microsoftonline.com/common/oauth2/v2.0/token')
        .with(body: { 'code' => code, 'grant_type' => 'authorization_code',
                      'redirect_uri' => "#{base_url}/microsoft/callback" })
        .to_return(status: 200, body: response_body_success.to_json, headers: { 'Content-Type' => 'application/json' })

      get microsoft_callback_url, params: { code: code, state: state }

      expect(response).to redirect_to app_email_inbox_settings_url(account_id: account.id, inbox_id: account.inboxes.last.id)
      expect(account.inboxes.count).to be 1
      expect(inbox.channel.reload.provider_config.keys).to include('access_token', 'refresh_token', 'expires_on')
      expect(inbox.channel.reload.provider_config['access_token']).to eq response_body_success[:access_token]
      expect(inbox.channel.imap_address).to eq 'outlook.office365.com'
    end

    it 'creates inboxes with fallback_name when account name is not present in id_token' do
      stub_request(:post, 'https://login.microsoftonline.com/common/oauth2/v2.0/token')
        .with(body: { 'code' => code, 'grant_type' => 'authorization_code',
                      'redirect_uri' => "#{base_url}/microsoft/callback" })
        .to_return(status: 200, body: response_body_success_without_name.to_json, headers: { 'Content-Type' => 'application/json' })

      get microsoft_callback_url, params: { code: code, state: state }

      expect(response).to redirect_to app_email_inbox_agents_url(account_id: account.id, inbox_id: account.inboxes.last.id)
      expect(account.inboxes.count).to be 1
      inbox = account.inboxes.last
      expect(inbox.name).to eq email.split('@').first.parameterize.titleize
    end

    it 'preserves the existing refresh token when microsoft does not return a new one' do
      existing_refresh_token = SecureRandom.hex(10)
      inbox = create(
        :channel_email,
        account: account,
        email: email,
        provider_config: {
          access_token: SecureRandom.hex(10),
          refresh_token: existing_refresh_token,
          expires_on: 1.hour.from_now.utc.to_s
        }
      )&.inbox

      stub_request(:post, 'https://login.microsoftonline.com/common/oauth2/v2.0/token')
        .with(body: { 'code' => code, 'grant_type' => 'authorization_code',
                      'redirect_uri' => "#{base_url}/microsoft/callback" })
        .to_return(
          status: 200,
          body: response_body_success.except(:refresh_token).to_json,
          headers: { 'Content-Type' => 'application/json' }
        )

      get microsoft_callback_url, params: { code: code, state: state }

      expect(response).to redirect_to app_email_inbox_settings_url(account_id: account.id, inbox_id: inbox.id)
      expect(inbox.channel.reload.provider_config['refresh_token']).to eq(existing_refresh_token)
    end

    it 'does not create an inbox when microsoft callback does not include a refresh token for a new connection' do
      stub_request(:post, 'https://login.microsoftonline.com/common/oauth2/v2.0/token')
        .with(body: { 'code' => code, 'grant_type' => 'authorization_code',
                      'redirect_uri' => "#{base_url}/microsoft/callback" })
        .to_return(
          status: 200,
          body: response_body_success.except(:refresh_token).to_json,
          headers: { 'Content-Type' => 'application/json' }
        )

      expect do
        get microsoft_callback_url, params: { code: code, state: state }
      end.not_to change(account.inboxes, :count)

      expect(response).to redirect_to("#{base_url}/app/accounts/#{account.id}/settings/inboxes/new/microsoft?error=oauth_callback_failed")
    end

    it 'redirects to microsoft app in case of error' do
      stub_request(:post, 'https://login.microsoftonline.com/common/oauth2/v2.0/token')
        .with(body: { 'code' => code, 'grant_type' => 'authorization_code',
                      'redirect_uri' => "#{base_url}/microsoft/callback" })
        .to_return(status: 401)

      get microsoft_callback_url, params: { code: code, state: state }

      expect(response).to redirect_to("#{base_url}/app/accounts/#{account.id}/settings/inboxes/new/microsoft?error=oauth_callback_failed")
    end

    it 'uses expires_in from the oauth response when provided' do
      freeze_time do
        stub_request(:post, 'https://login.microsoftonline.com/common/oauth2/v2.0/token')
          .with(body: { 'code' => code, 'grant_type' => 'authorization_code',
                        'redirect_uri' => "#{base_url}/microsoft/callback" })
          .to_return(
            status: 200,
            body: response_body_success.merge(expires_in: 7200).to_json,
            headers: { 'Content-Type' => 'application/json' }
          )

        get microsoft_callback_url, params: { code: code, state: state }

        expires_on = Time.zone.parse(account.inboxes.last.channel.reload.provider_config['expires_on'])
        expect(expires_on).to be_within(1.second).of(2.hours.from_now)
      end
    end
  end
end
