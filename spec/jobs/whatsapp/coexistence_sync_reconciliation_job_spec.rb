require 'rails_helper'

RSpec.describe Whatsapp::CoexistenceSyncReconciliationJob do
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
  let(:service) { instance_double(Whatsapp::CoexistenceSyncReconciliationService) }

  before do
    allow(Whatsapp::CoexistenceSyncReconciliationService).to receive(:new).with(channel).and_return(service)
  end

  it 'uses the dedicated WhatsApp history queue served in DEV and production' do
    expect(described_class.queue_name).to eq('whatsappweb_history')
  end

  it 'holds the WABA lock while reconciling an unknown provider outcome' do
    lock = instance_double(Whatsapp::WabaLock)
    lock_held = false
    allow(Whatsapp::WabaLock).to receive(:new).with(channel.provider_config['business_account_id']).and_return(lock)
    allow(lock).to receive(:with_lock) do |&block|
      lock_held = true
      block.call
    ensure
      lock_held = false
    end
    expect(service).to receive(:reconcile_unknown_outcome!).with(generation: 'generation-1') do
      expect(lock_held).to be(true)
      :resolved
    end

    described_class.perform_now(channel.id, 'generation-1')
  end

  it 're-enqueues itself while the unknown request remains inside its deadline' do
    allow(service).to receive(:reconcile_unknown_outcome!).and_return(:waiting)

    expect do
      described_class.perform_now(channel.id, 'generation-1')
    end.to have_enqueued_job(described_class).with(channel.id, 'generation-1')
  end

  it 'does not reconcile after the queued inbox starts deleting' do
    channel.inbox.update!(deleting_at: Time.current)
    expect(Whatsapp::WabaLock).not_to receive(:new)
    expect(Whatsapp::CoexistenceSyncReconciliationService).not_to receive(:new)

    described_class.perform_now(channel.id, 'generation-1')
  end

  it 'does not reconcile under a stale WABA lock after channel identity changes' do
    original_waba_id = channel.provider_config['business_account_id']
    lock = instance_double(Whatsapp::WabaLock)
    allow(Whatsapp::WabaLock).to receive(:new).with(original_waba_id).and_return(lock)
    allow(lock).to receive(:with_lock) do |&block|
      channel.update!(provider_config: channel.provider_config.merge('business_account_id' => 'waba-2'))
      block.call
    end
    expect(Whatsapp::CoexistenceSyncReconciliationService).not_to receive(:new)

    described_class.perform_now(channel.id, 'generation-1')
  end

  it 'stops polling after manual recovery is required' do
    allow(service).to receive(:reconcile_unknown_outcome!).and_return(:manual_recovery_required)

    expect do
      described_class.perform_now(channel.id, 'generation-1')
    end.not_to have_enqueued_job(described_class)
  end
end
