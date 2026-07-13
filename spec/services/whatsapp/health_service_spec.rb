require 'rails_helper'

RSpec.describe Whatsapp::HealthService do
  let(:api_version) { 'v22.0' }
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
    allow(GlobalConfigService).to receive(:load).with('WHATSAPP_API_VERSION', 'v22.0').and_return(api_version)
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
          messaging_limit_tier: 'TIER_1000',
          account_mode: 'LIVE',
          platform_type: 'CLOUD_API',
          throughput: { 'level' => 'STANDARD' }
        }.to_json,
        headers: { 'Content-Type' => 'application/json' }
      )

    result = described_class.new(whatsapp_channel).fetch_health_status

    expect(result[:verified_name]).to eq('Healthy Business')
    expect(result[:business_id]).to eq('business-1')
    expect(whatsapp_channel.reload.reauthorization_required?).to be(false)
    expect(whatsapp_channel.provider_config).not_to include('authorization_status')
    expect(whatsapp_channel.provider_config).not_to include('authorization_error')
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
          messaging_limit_tier: 'TIER_1000',
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
end
