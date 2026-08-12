require 'rails_helper'

RSpec.describe 'WhatsApp Phone Registration API', type: :request do
  let(:account) { create(:account) }
  let(:admin) { create(:user, account: account, role: :administrator) }
  let(:channel) do
    create(
      :channel_whatsapp,
      account: account,
      provider: 'whatsapp_cloud',
      provider_config: {
        'api_key' => 'access-token',
        'business_account_id' => 'waba-1',
        'phone_number_id' => 'phone-1',
        'embedded_signup_flow' => 'standard',
        'phone_registration' => { 'status' => 'pin_incorrect' }
      },
      sync_templates: false,
      validate_provider_config: false
    )
  end
  let(:inbox) { channel.inbox }
  let(:path) { "/api/v1/accounts/#{account.id}/whatsapp/phone_registration" }

  it 'requires authentication' do
    post path, params: { inbox_id: inbox.id, verification_pin: '123456' }, as: :json

    expect(response).to have_http_status(:unauthorized)
  end

  it 'registers the account-owned standard Cloud number without exposing the PIN' do
    registration_service = instance_double(Whatsapp::WebhookSetupService)
    expect(Whatsapp::WebhookSetupService).to receive(:new).with(an_instance_of(Channel::Whatsapp)).and_return(registration_service)
    expect(registration_service).to receive(:register_phone_number_with_pin!).with('123456') do
      channel.reload
      config = channel.provider_config.merge(
        'verification_pin' => '123456',
        'phone_registration' => { 'status' => 'registered', 'completed_at' => Time.current.iso8601 }
      )
      channel.persist_provider_config_state!(config)
    end

    post path,
         params: { inbox_id: inbox.id, verification_pin: '123456' },
         headers: admin.create_new_auth_token,
         as: :json

    expect(response).to have_http_status(:success)
    expect(response.parsed_body).to include('success' => true, 'inbox_id' => inbox.id)
    expect(response.parsed_body['provider_config']).not_to have_key('verification_pin')
    expect(response.parsed_body.dig('provider_config', 'phone_registration', 'status')).to eq('registered')
  end

  it 'rejects an inbox from another account before invoking the provider' do
    foreign_channel = create(:channel_whatsapp, provider: 'whatsapp_cloud', sync_templates: false, validate_provider_config: false)
    expect(Whatsapp::WebhookSetupService).not_to receive(:new)

    post path,
         params: { inbox_id: foreign_channel.inbox.id, verification_pin: '123456' },
         headers: admin.create_new_auth_token,
         as: :json

    expect(response).to have_http_status(:not_found)
  end

  it 'rejects coexistence channels because Meta registration is not their lifecycle' do
    channel.persist_provider_config_state!(channel.provider_config.merge('embedded_signup_flow' => 'coexistence'))
    expect(Whatsapp::WebhookSetupService).not_to receive(:new)

    post path,
         params: { inbox_id: inbox.id, verification_pin: '123456' },
         headers: admin.create_new_auth_token,
         as: :json

    expect(response).to have_http_status(:unprocessable_content)
    expect(response.parsed_body['error_code']).to eq('invalid_inbox_channel')
  end

  it 'returns a typed PIN mismatch without echoing the PIN' do
    error = Whatsapp::PhoneRegistrationService::Error.new(error_code: 'pin_incorrect', provider_code: 133_005)
    registration_service = instance_double(Whatsapp::WebhookSetupService)
    allow(Whatsapp::WebhookSetupService).to receive(:new).and_return(registration_service)
    allow(registration_service).to receive(:register_phone_number_with_pin!).and_raise(error)

    post path,
         params: { inbox_id: inbox.id, verification_pin: '123456' },
         headers: admin.create_new_auth_token,
         as: :json

    expect(response).to have_http_status(:unprocessable_content)
    expect(response.parsed_body).to include('error_code' => 'pin_incorrect', 'provider_error_code' => 133_005)
    expect(response.parsed_body['provider_config']).not_to have_key('verification_pin')
  end

  it 'does not submit the PIN again after registration has completed' do
    channel.persist_provider_config_state!(
      channel.provider_config.merge('phone_registration' => { 'status' => 'registered' })
    )
    expect(Whatsapp::WebhookSetupService).not_to receive(:new)

    post path,
         params: { inbox_id: inbox.id, verification_pin: '123456' },
         headers: admin.create_new_auth_token,
         as: :json

    expect(response).to have_http_status(:unprocessable_content)
    expect(response.parsed_body['error_code']).to eq('registration_not_required')
  end

  it 'does not allow registration without a server-owned recovery ledger' do
    channel.persist_provider_config_state!(channel.provider_config.except('phone_registration'))
    expect(Whatsapp::WebhookSetupService).not_to receive(:new)

    post path,
         params: { inbox_id: inbox.id, verification_pin: '123456' },
         headers: admin.create_new_auth_token,
         as: :json

    expect(response).to have_http_status(:unprocessable_content)
    expect(response.parsed_body['error_code']).to eq('registration_not_required')
  end

  it 'returns conflict without retrying an unknown provider outcome' do
    channel.persist_provider_config_state!(
      channel.provider_config.merge('phone_registration' => { 'status' => 'outcome_unknown' })
    )
    registration_service = instance_double(Whatsapp::WebhookSetupService)
    allow(Whatsapp::WebhookSetupService).to receive(:new).and_return(registration_service)
    expect(registration_service).to receive(:register_phone_number_with_pin!).and_raise(
      Whatsapp::PhoneRegistrationService::Error.new(error_code: 'outcome_unknown')
    )

    post path,
         params: { inbox_id: inbox.id, verification_pin: '123456' },
         headers: admin.create_new_auth_token,
         as: :json

    expect(response).to have_http_status(:conflict)
    expect(response.parsed_body['error_code']).to eq('outcome_unknown')
  end

  it 'does not let PIN recovery bypass a hard token failure' do
    channel.persist_provider_config_state!(
      channel.provider_config.merge(
        'authorization_status' => 'reauthorization_required',
        'phone_registration' => { 'status' => 'pin_incorrect' }
      )
    )
    expect(Whatsapp::WebhookSetupService).not_to receive(:new)

    post path,
         params: { inbox_id: inbox.id, verification_pin: '123456' },
         headers: admin.create_new_auth_token,
         as: :json

    expect(response).to have_http_status(:unprocessable_content)
    expect(response.parsed_body['error_code']).to eq('reauthorization_required')
  end

  it 'keeps reauthorization required while webhook recovery is unresolved' do
    channel.prompt_reauthorization!
    channel.persist_provider_config_state!(
      channel.provider_config.merge(
        'webhook_callback_recovery' => { 'state' => 'manual_recovery_required' }
      )
    )
    registration_service = instance_double(Whatsapp::WebhookSetupService)
    allow(Whatsapp::WebhookSetupService).to receive(:new).and_return(registration_service)
    allow(registration_service).to receive(:register_phone_number_with_pin!) do
      channel.persist_provider_config_state!(
        channel.provider_config.merge('phone_registration' => { 'status' => 'registered' })
      )
    end

    post path,
         params: { inbox_id: inbox.id, verification_pin: '123456' },
         headers: admin.create_new_auth_token,
         as: :json

    expect(response).to have_http_status(:success)
    expect(response.parsed_body['reauthorization_required']).to be(true)
  end

  it 'never clears a generic reauthorization flag after phone registration succeeds' do
    channel.prompt_reauthorization!
    registration_service = instance_double(Whatsapp::WebhookSetupService)
    allow(Whatsapp::WebhookSetupService).to receive(:new).and_return(registration_service)
    allow(registration_service).to receive(:register_phone_number_with_pin!) do
      channel.persist_provider_config_state!(
        channel.provider_config.merge('phone_registration' => { 'status' => 'registered' })
      )
    end

    post path,
         params: { inbox_id: inbox.id, verification_pin: '123456' },
         headers: admin.create_new_auth_token,
         as: :json

    expect(response).to have_http_status(:success)
    expect(response.parsed_body['reauthorization_required']).to be(true)
  end
end
