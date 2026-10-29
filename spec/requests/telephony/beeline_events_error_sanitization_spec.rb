# frozen_string_literal: true

require 'rails_helper'

RSpec.describe 'Telephony::BeelineEvents error sanitization', type: :request do
  let(:account) { create(:account) }
  let(:webhook_token) { 'beeline-sanitize-token-12345' }
  let(:connection) do
    create(:telephony_provider_connection, account: account, provider_kind: 'beeline', status: 'active')
  end
  let(:voice_channel) do
    Channel::Voice.create!(
      account: account,
      provider: 'beeline',
      phone_number: '+77761234568',
      provider_config: {
        'provider_kind' => 'beeline',
        'number_ref' => 'num-beeline-sanitize-1',
        'provider_connection_id' => connection.id,
        'routing_mode' => 'operator',
        'display_phone_number' => '+77761234568',
        'ingress_number' => '+77761234568',
        'beeline_events_webhook_token' => webhook_token
      }
    )
  end

  before do
    create(:inbox, account: account, channel: voice_channel, name: 'Beeline Sanitize')
  end

  it 'does not leak internal exception messages in HTTP responses when processing fails' do
    allow(Telephony::Beeline::EventAdapter).to receive(:new).and_raise(StandardError, 'pg_password=secret_internal_detail')

    post "/beeline/events/#{webhook_token}",
         params: '<xsi:Event/>',
         headers: { 'CONTENT_TYPE' => 'application/xml' }

    expect(response).to have_http_status(:unprocessable_entity)
    expect(response.parsed_body).to eq('ok' => false, 'error' => 'Webhook processing failed')
    expect(response.body).not_to include('secret_internal_detail')
  end
end
