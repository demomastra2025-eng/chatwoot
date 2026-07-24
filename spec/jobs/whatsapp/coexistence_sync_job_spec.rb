require 'rails_helper'

RSpec.describe Whatsapp::CoexistenceSyncJob do
  let(:channel) do
    create(
      :channel_whatsapp,
      provider: 'whatsapp_cloud',
      validate_provider_config: false,
      sync_templates: false,
      provider_config: {
        'api_key' => 'token',
        'phone_number_id' => 'phone-1',
        'business_account_id' => 'waba-1',
        'embedded_signup_flow' => 'coexistence',
        'coexistence_sync' => { 'generation' => 'generation-1' }
      }
    )
  end

  it 'uses the dedicated WhatsApp history queue served in DEV and production' do
    expect(described_class.queue_name).to eq('whatsappweb_history')
  end

  it 'schedules durable reconciliation when a one-time request outcome is unknown' do
    service = instance_double(Whatsapp::CoexistenceSyncService)
    allow(Whatsapp::CoexistenceSyncService).to receive(:new)
      .with(channel, generation: 'generation-1').and_return(service)
    allow(service).to receive(:perform)
      .and_raise(Whatsapp::CoexistenceSyncService::RequestOutcomeUnknownError, 'outcome unknown')

    expect do
      described_class.perform_now(channel.id, 'generation-1')
    end.to have_enqueued_job(Whatsapp::CoexistenceSyncReconciliationJob).with(channel.id, 'generation-1')
  end

  it 'drops a worker from an older synchronization generation' do
    config = channel.provider_config.deep_dup
    config['coexistence_sync']['generation'] = 'generation-2'
    channel.update!(provider_config: config)
    expect(Whatsapp::CoexistenceSyncService).not_to receive(:new)

    described_class.perform_now(channel.id, 'generation-1')
  end
end
