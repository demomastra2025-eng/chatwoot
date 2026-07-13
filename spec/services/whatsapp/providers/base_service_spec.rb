require 'rails_helper'

RSpec.describe Whatsapp::Providers::BaseService do
  let(:channel_token) { 'whatsapp-provider-secret-token' }
  let(:channel) do
    create(
      :channel_whatsapp,
      provider: 'whatsapp_cloud',
      provider_config: { 'api_key' => channel_token },
      validate_provider_config: false,
      sync_templates: false
    )
  end

  it 'redacts provider response and exception credentials before logging' do
    response = instance_double(
      HTTParty::Response,
      body: { access_token: channel_token, refresh_token: 'refresh-secret' }.to_json,
      parsed_response: { 'error' => { 'message' => "token=#{channel_token}" } }
    )
    log_messages = []
    allow(channel).to receive(:record_provider_authorization_error!)
      .and_raise(StandardError, "code=oauth-secret access_token=#{channel_token}")
    allow(Rails.logger).to receive(:error) { |message| log_messages << message }

    described_class.new(whatsapp_channel: channel).handle_error(response, nil)

    combined_log = log_messages.join
    expect(combined_log).to include('[FILTERED]')
    expect(combined_log).not_to include(channel_token, 'refresh-secret', 'oauth-secret')
  end
end
