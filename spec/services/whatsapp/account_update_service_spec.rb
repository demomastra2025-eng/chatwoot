require 'rails_helper'

RSpec.describe Whatsapp::AccountUpdateService do
  include ActiveJob::TestHelper

  let(:channel) do
    create(:channel_whatsapp,
           provider: 'whatsapp_cloud',
           sync_templates: false,
           validate_provider_config: false,
           provider_config: {
             'api_key' => 'wa-token',
             'phone_number_id' => 'phone-1',
             'business_account_id' => '123456789',
             'source' => 'embedded_signup'
           })
  end

  def payload(event:, waba_id: '123456789', value: {})
    {
      object: 'whatsapp_business_account',
      entry: [{
        id: waba_id,
        time: 1_725_000_000,
        changes: [{ field: 'account_update', value: value.merge(event: event) }]
      }]
    }
  end

  it 'records an offboarding event and requires reauthorization once' do
    allow(channel).to receive(:record_provider_configuration_error!)
    params = payload(event: 'ACCOUNT_OFFBOARDED')

    2.times { described_class.new(channel: channel, params: params).perform }

    expect(channel).to have_received(:record_provider_configuration_error!)
      .with(/ACCOUNT_OFFBOARDED/, type: 'WhatsAppAccountUpdate').once
    expect(channel.reload.provider_config.dig('provider_lifecycle', 'event')).to eq('ACCOUNT_OFFBOARDED')
  end

  it 'does not consume an event when its lifecycle action fails' do
    params = payload(event: 'ACCOUNT_OFFBOARDED')
    allow(channel).to receive(:record_provider_configuration_error!).and_raise(StandardError, 'write failed')

    expect { described_class.new(channel: channel, params: params).perform }.to raise_error(StandardError, 'write failed')
    expect(channel.reload.provider_config).not_to include('provider_lifecycle')

    allow(channel).to receive(:record_provider_configuration_error!).and_return(true)
    described_class.new(channel: channel, params: params).perform

    expect(channel.reload.provider_config.dig('provider_lifecycle', 'event')).to eq('ACCOUNT_OFFBOARDED')
  end

  it 'queues a scoped token-health verification after reconnection' do
    expect do
      described_class.new(channel: channel, params: payload(event: 'ACCOUNT_RECONNECTED')).perform
    end.to have_enqueued_job(Whatsapp::TokenHealthCheckChannelJob).with(channel.id).once
  end

  it 'records policy restrictions without presenting reconnect as the remedy' do
    allow(channel).to receive(:record_provider_configuration_error!)

    described_class.new(
      channel: channel,
      params: payload(event: 'ACCOUNT_RESTRICTION', value: { restriction_info: [{ restriction_type: 'MESSAGING' }] })
    ).perform

    expect(channel).not_to have_received(:record_provider_configuration_error!)
    expect(channel.reload.meta_credential_health).to have_attributes(status: 'action_required', reason: 'policy_restricted')
  end

  it 'ignores an account update for a different WABA' do
    allow(channel).to receive(:store_provider_lifecycle_event!)

    described_class.new(channel: channel, params: payload(event: 'ACCOUNT_OFFBOARDED', waba_id: 'other-waba')).perform

    expect(channel).not_to have_received(:store_provider_lifecycle_event!)
  end
end
