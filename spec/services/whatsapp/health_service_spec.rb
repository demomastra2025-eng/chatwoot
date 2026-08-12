require 'rails_helper'

RSpec.describe Whatsapp::HealthService do
  let(:api_version) { 'v25.0' }
  let(:whatsapp_channel) do
    create(:channel_whatsapp, provider: 'whatsapp_cloud',
                              provider_config: {
                                'api_key' => 'token-1',
                                'phone_number_id' => '123456789',
                                'business_account_id' => 'waba-1',
                                'business_id' => 'business-1',
                                'source' => 'embedded_signup'
                              },
                              validate_provider_config: false, sync_templates: false)
  end

  before do
    allow(GlobalConfigService).to receive(:load).and_call_original
    allow(GlobalConfigService).to receive(:load).with('WHATSAPP_API_VERSION', 'v25.0').and_return(api_version)
  end

  it 'marks the channel for reauthorization when Meta health check returns an invalid token error' do
    stub_request(:get, %r{https://graph\.facebook\.com/#{api_version}/123456789})
      .to_return(
        status: 401,
        body: {
          error: {
            message: 'Error validating access token: Session has expired',
            type: 'OAuthException',
            code: 190,
            fbtrace_id: 'trace-health-190'
          }
        }.to_json,
        headers: { 'Content-Type' => 'application/json' }
      )

    expect { described_class.new(whatsapp_channel).fetch_health_status }
      .to raise_error(RuntimeError, /WhatsApp API request failed/)

    expect(whatsapp_channel.reload.reauthorization_required?).to be(true)
    expect(whatsapp_channel.provider_config).to include(
      'authorization_status' => 'reauthorization_required',
      'authorization_error' => hash_including(
        'code' => 190,
        'type' => 'OAuthException',
        'message' => include('Error validating access token')
      )
    )
  end

  it 'does not apply an authorization error from credentials rotated during the health request' do
    stub_request(:get, %r{https://graph\.facebook\.com/#{api_version}/123456789})
      .to_return do
        whatsapp_channel.with_lock do
          whatsapp_channel.reload
          whatsapp_channel.persist_provider_config_state!(whatsapp_channel.provider_config.merge('api_key' => 'token-2'))
        end
        {
          status: 401,
          body: { error: { message: 'Old token expired', type: 'OAuthException', code: 190 } }.to_json,
          headers: { 'Content-Type' => 'application/json' }
        }
      end

    expect { described_class.new(whatsapp_channel).fetch_health_status }
      .to raise_error(described_class::StaleProviderIdentityError)

    config = whatsapp_channel.reload.provider_config
    expect(config['api_key']).to eq('token-2')
    expect(config).not_to include('authorization_status', 'authorization_error')
    expect(whatsapp_channel.reauthorization_required?).to be(false)
  end

  it 'does not reconcile phone registration from credentials rotated during the health request' do
    whatsapp_channel.persist_provider_config_state!(
      whatsapp_channel.provider_config.merge(
        'phone_registration' => { 'status' => 'outcome_unknown', 'failed_at' => 1.hour.ago.iso8601 }
      )
    )
    stub_request(:get, %r{https://graph\.facebook\.com/#{api_version}/123456789})
      .to_return do
        whatsapp_channel.with_lock do
          whatsapp_channel.reload
          whatsapp_channel.persist_provider_config_state!(whatsapp_channel.provider_config.merge('api_key' => 'token-2'))
        end
        {
          status: 200,
          body: { id: '123456789', platform_type: 'CLOUD_API', throughput: { level: 'STANDARD' } }.to_json,
          headers: { 'Content-Type' => 'application/json' }
        }
      end

    expect { described_class.new(whatsapp_channel).fetch_health_status }
      .to raise_error(described_class::StaleProviderIdentityError)

    config = whatsapp_channel.reload.provider_config
    expect(config['api_key']).to eq('token-2')
    expect(config.dig('phone_registration', 'status')).to eq('outcome_unknown')
  end

  it 'redacts credentials from provider-config errors, raised errors, and logs' do
    channel_token = whatsapp_channel.provider_config['api_key']
    body = {
      error: {
        message: "access_token=#{channel_token} code=one-time-code",
        type: 'OAuthException',
        code: 190,
        refresh_token: 'refresh-secret'
      }
    }.to_json
    stub_request(:get, %r{https://graph\.facebook\.com/#{api_version}/123456789})
      .to_return(status: 401, body: body, headers: { 'Content-Type' => 'application/json' })
    logged_messages = []
    allow(Rails.logger).to receive(:error) { |message| logged_messages << message }

    raised_message = nil
    expect { described_class.new(whatsapp_channel).fetch_health_status }
      .to raise_error(RuntimeError) { |error| raised_message = error.message }

    persisted_error = whatsapp_channel.reload.provider_config['authorization_error'].to_json
    [persisted_error, raised_message, logged_messages.join].each do |output|
      expect(output).to include('[FILTERED]')
      expect(output).not_to include(channel_token, 'one-time-code', 'refresh-secret')
    end
  end

  it 'automatically clears a stale reauthorization flag when health check is healthy' do
    whatsapp_channel.record_provider_configuration_error!('Expired token', type: 'OAuthException')

    stub_request(:get, %r{https://graph\.facebook\.com/#{api_version}/123456789})
      .to_return(
        status: 200,
        body: {
          id: '123456789',
          display_phone_number: '+123****7890',
          verified_name: 'Healthy Business',
          name_status: 'APPROVED',
          quality_rating: 'GREEN',
          whatsapp_business_manager_messaging_limit: 10_000,
          account_mode: 'LIVE',
          platform_type: 'CLOUD_API',
          throughput: { 'level' => 'STANDARD' }
        }.to_json,
        headers: { 'Content-Type' => 'application/json' }
      )

    result = described_class.new(whatsapp_channel).fetch_health_status

    expect(result[:verified_name]).to eq('Healthy Business')
    expect(result[:messaging_limit]).to eq(10_000)
    expect(result[:business_id]).to eq('business-1')
    expect(whatsapp_channel.reload.reauthorization_required?).to be(false)
    expect(whatsapp_channel.provider_config).not_to include('authorization_status')
    expect(whatsapp_channel.provider_config).not_to include('authorization_error')
  end

  it 'sends the access token only in the Authorization header and reports the embedded callback URL' do
    access_token = whatsapp_channel.provider_config.fetch('api_key')
    request = stub_request(:get, %r{https://graph\.facebook\.com/#{api_version}/123456789})
              .with do |provider_request|
      query = URI.decode_www_form(provider_request.uri.query.to_s).to_h
      provider_request.headers['Authorization'] == "Bearer #{access_token}" && !query.key?('access_token')
    end.to_return(status: 200, body: { id: '123456789' }.to_json, headers: { 'Content-Type' => 'application/json' })

    with_modified_env('FRONTEND_URL' => 'https://app.example.test') do
      result = described_class.new(whatsapp_channel).fetch_health_status
      expect(result[:expected_webhook_url]).to eq('https://app.example.test/webhooks/whatsapp')
    end
    expect(request).to have_been_requested.once
  end

  it 'reports the channel-bound callback URL for manual channels' do
    whatsapp_channel.update!(provider_config: whatsapp_channel.provider_config.merge('source' => 'manual'))
    stub_request(:get, %r{https://graph\.facebook\.com/#{api_version}/123456789})
      .to_return(status: 200, body: { id: '123456789' }.to_json, headers: { 'Content-Type' => 'application/json' })

    with_modified_env('FRONTEND_URL' => 'https://app.example.test') do
      result = described_class.new(whatsapp_channel).fetch_health_status
      expect(result[:expected_webhook_url])
        .to eq("https://app.example.test/webhooks/whatsapp?channel_id=#{whatsapp_channel.id}")
    end
  end

  it 'does not clear a non-token reauthorization flag when health check is healthy' do
    whatsapp_channel.prompt_reauthorization!

    stub_request(:get, %r{https://graph\.facebook\.com/#{api_version}/123456789})
      .to_return(
        status: 200,
        body: {
          id: '123456789',
          display_phone_number: '+123****7890',
          verified_name: 'Healthy Business',
          name_status: 'APPROVED',
          quality_rating: 'GREEN',
          whatsapp_business_manager_messaging_limit: 10_000,
          account_mode: 'LIVE',
          platform_type: 'CLOUD_API',
          throughput: { 'level' => 'STANDARD' }
        }.to_json,
        headers: { 'Content-Type' => 'application/json' }
      )

    result = described_class.new(whatsapp_channel).fetch_health_status

    expect(result[:verified_name]).to eq('Healthy Business')
    expect(whatsapp_channel.reload.reauthorization_required?).to be(true)
  end

  it 'bootstraps a registration recovery ledger only from pending Meta health' do
    stub_request(:get, %r{https://graph\.facebook\.com/#{api_version}/123456789})
      .to_return(
        status: 200,
        body: {
          id: '123456789',
          platform_type: 'NOT_APPLICABLE',
          throughput: { 'level' => 'NOT_APPLICABLE' }
        }.to_json,
        headers: { 'Content-Type' => 'application/json' }
      )

    described_class.new(whatsapp_channel).fetch_health_status

    expect(whatsapp_channel.reload.provider_config.fetch('phone_registration')).to include(
      'status' => 'registration_incomplete',
      'detected_at' => be_present
    )
  end

  it 'does not overwrite a typed registration failure during health reconciliation' do
    whatsapp_channel.persist_provider_config_state!(
      whatsapp_channel.provider_config.merge(
        'phone_registration' => { 'status' => 'pin_incorrect', 'provider_error_code' => 133_005 }
      )
    )
    stub_request(:get, %r{https://graph\.facebook\.com/#{api_version}/123456789})
      .to_return(
        status: 200,
        body: { id: '123456789', platform_type: 'NOT_APPLICABLE' }.to_json,
        headers: { 'Content-Type' => 'application/json' }
      )

    described_class.new(whatsapp_channel).fetch_health_status

    expect(whatsapp_channel.reload.provider_config['phone_registration']).to eq(
      'status' => 'pin_incorrect', 'provider_error_code' => 133_005
    )
  end

  it 'does not create a phone-registration lifecycle for coexistence channels' do
    whatsapp_channel.persist_provider_config_state!(
      whatsapp_channel.provider_config.merge('embedded_signup_flow' => 'coexistence')
    )
    stub_request(:get, %r{https://graph\.facebook\.com/#{api_version}/123456789})
      .to_return(
        status: 200,
        body: { id: '123456789', platform_type: 'NOT_APPLICABLE' }.to_json,
        headers: { 'Content-Type' => 'application/json' }
      )

    described_class.new(whatsapp_channel).fetch_health_status

    expect(whatsapp_channel.reload.provider_config).not_to have_key('phone_registration')
  end

  it 'reconciles an unknown provider outcome to registered from active Cloud health' do
    registration_api_client = instance_double(Whatsapp::FacebookApiClient)
    allow(registration_api_client).to receive(:register_phone_number).and_raise(Timeout::Error, 'timed out')
    expect do
      Whatsapp::PhoneRegistrationService.new(whatsapp_channel, api_client: registration_api_client).perform(pin: '654321')
    end.to raise_error(Whatsapp::PhoneRegistrationService::Error, 'outcome_unknown')

    stub_request(:get, %r{https://graph\.facebook\.com/#{api_version}/123456789})
      .to_return(
        status: 200,
        body: { id: '123456789', platform_type: 'CLOUD_API', throughput: { level: 'STANDARD' } }.to_json,
        headers: { 'Content-Type' => 'application/json' }
      )

    travel 11.minutes
    result = described_class.new(whatsapp_channel).fetch_health_status

    config = whatsapp_channel.reload.provider_config
    expect(config['verification_pin']).to be_nil
    expect(config.dig('phone_registration', 'status')).to eq('registered')
    expect(config.dig('phone_registration', Whatsapp::PhoneRegistrationService::PENDING_PIN_CIPHERTEXT_KEY)).to be_nil
    expect(result[:phone_registration]).to include('status' => 'registered', 'completed_at' => be_present)
    expect(result.to_json).not_to include('pending_pin_ciphertext')
  end

  it 'reopens PIN recovery without retrying Meta when health confirms registration is pending' do
    registration_api_client = instance_double(Whatsapp::FacebookApiClient)
    allow(registration_api_client).to receive(:register_phone_number).and_raise(Timeout::Error, 'timed out')
    expect do
      Whatsapp::PhoneRegistrationService.new(whatsapp_channel, api_client: registration_api_client).perform(pin: '654321')
    end.to raise_error(Whatsapp::PhoneRegistrationService::Error, 'outcome_unknown')

    stub_request(:get, %r{https://graph\.facebook\.com/#{api_version}/123456789})
      .to_return(
        status: 200,
        body: { id: '123456789', platform_type: 'NOT_APPLICABLE' }.to_json,
        headers: { 'Content-Type' => 'application/json' }
      )

    travel 11.minutes
    described_class.new(whatsapp_channel).fetch_health_status

    config = whatsapp_channel.reload.provider_config
    expect(config).not_to have_key('verification_pin')
    expect(config.dig('phone_registration', 'status')).to eq('registration_incomplete')
    expect(config.dig('phone_registration', Whatsapp::PhoneRegistrationService::PENDING_PIN_CIPHERTEXT_KEY)).to be_nil
  end

  it 'does not overwrite a recent successful registration with stale pending health' do
    whatsapp_channel.persist_provider_config_state!(
      whatsapp_channel.provider_config.merge(
        'phone_registration' => { 'status' => 'registered', 'completed_at' => 1.minute.ago.iso8601 }
      )
    )
    stub_request(:get, %r{https://graph\.facebook\.com/#{api_version}/123456789})
      .to_return(
        status: 200,
        body: { id: '123456789', platform_type: 'NOT_APPLICABLE' }.to_json,
        headers: { 'Content-Type' => 'application/json' }
      )

    described_class.new(whatsapp_channel).fetch_health_status

    expect(whatsapp_channel.reload.provider_config.dig('phone_registration', 'status')).to eq('registered')
  end

  it 'reopens registration recovery when pending health persists beyond the grace period' do
    whatsapp_channel.persist_provider_config_state!(
      whatsapp_channel.provider_config.merge(
        'phone_registration' => { 'status' => 'registered', 'completed_at' => 1.hour.ago.iso8601 }
      )
    )
    stub_request(:get, %r{https://graph\.facebook\.com/#{api_version}/123456789})
      .to_return(
        status: 200,
        body: { id: '123456789', platform_type: 'NOT_APPLICABLE' }.to_json,
        headers: { 'Content-Type' => 'application/json' }
      )

    described_class.new(whatsapp_channel).fetch_health_status

    expect(whatsapp_channel.reload.provider_config.dig('phone_registration', 'status')).to eq('registration_incomplete')
  end
end
