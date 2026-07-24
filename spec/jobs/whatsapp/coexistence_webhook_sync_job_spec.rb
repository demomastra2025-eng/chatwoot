require 'rails_helper'

RSpec.describe Whatsapp::CoexistenceWebhookSyncJob do
  let(:channel) do
    create(
      :channel_whatsapp,
      provider: 'whatsapp_cloud',
      sync_templates: false,
      validate_provider_config: false
    )
  end

  before do
    channel.update!(
      provider_config: channel.provider_config.merge(
        'embedded_signup_flow' => 'coexistence',
        'coexistence_sync' => {
          'generation' => 'generation-1',
          'state' => 'requested',
          'history_request_state' => 'requested',
          'smb_app_state_sync_request_state' => 'requested'
        }
      )
    )
  end

  def routing_context(metadata: {})
    {
      business_account_id: channel.provider_config['business_account_id'],
      sync_generation: 'generation-1',
      metadata: metadata
    }
  end

  it 'uses the dedicated WhatsApp history queue' do
    expect(described_class.queue_name).to eq('whatsappweb_history')
  end

  it 'registers retries for media events that arrive before their history placeholder' do
    handled_errors = described_class.rescue_handlers.map(&:first)

    expect(handled_errors).to include('Whatsapp::CoexistenceHistoryService::MediaHydrationError')
  end

  it 'requires durable manual recovery after media hydration retries are exhausted' do
    service = instance_double(Whatsapp::CoexistenceHistoryService)
    allow(Whatsapp::CoexistenceHistoryService).to receive(:new).and_return(service)
    allow(service).to receive(:perform).and_raise(Whatsapp::CoexistenceHistoryService::MediaHydrationError)

    perform_enqueued_jobs do
      described_class.perform_later(channel.id, 'history', { history: [] }, routing_context)
    end

    expect(service).to have_received(:perform).exactly(8).times
    expect(channel.reload.reauthorization_required?).to be(true)
  end

  it 'dispatches history payloads to the history importer under the channel lock' do
    value = { history: [] }
    service = instance_double(Whatsapp::CoexistenceHistoryService, perform: true)
    reconciliation = instance_double(Whatsapp::CoexistenceSyncReconciliationService, reconcile_webhook!: true)
    job = described_class.new
    allow(job).to receive(:with_lock).and_yield
    expect(Whatsapp::CoexistenceHistoryService).to receive(:new)
      .with(channel: channel, value: value.with_indifferent_access)
      .and_return(service)
    expect(Whatsapp::CoexistenceSyncReconciliationService).to receive(:new).with(channel).and_return(reconciliation)

    job.perform(channel.id, 'history', value, routing_context)

    expect(reconciliation).to have_received(:reconcile_webhook!).with('history', generation: 'generation-1')
  end

  it 'holds the WABA lock through metadata-free dispatch' do
    service = instance_double(Whatsapp::CoexistenceHistoryService)
    allow(Whatsapp::CoexistenceHistoryService).to receive(:new).and_return(service)
    allow(service).to receive(:perform) do
      result = Queue.new
      contender = Thread.new do
        Whatsapp::WabaLock.new(channel.provider_config['business_account_id']).with_lock { result << :acquired }
      rescue Whatsapp::WabaLock::LockAcquisitionError
        result << :blocked
      end

      expect(result.pop).to eq(:blocked)
      contender.value
    end

    described_class.perform_now(channel.id, 'history', { history: [] }, routing_context)

    expect(service).to have_received(:perform)
  end

  it 'does not import coexistence payloads for an inbox pending deletion' do
    channel.inbox.update!(deleting_at: Time.current)

    expect(Whatsapp::CoexistenceHistoryService).not_to receive(:new)

    described_class.perform_now(channel.id, 'history', { history: [] }, routing_context)
  end

  it 'does not import coexistence payloads for a standard Cloud channel' do
    channel.update!(provider_config: channel.provider_config.merge('embedded_signup_flow' => 'standard'))

    expect(Whatsapp::CoexistenceHistoryService).not_to receive(:new)

    described_class.perform_now(channel.id, 'history', { history: [] }, routing_context)
  end

  it 'drops a queued callback from an older synchronization generation' do
    config = channel.provider_config.deep_dup
    config['coexistence_sync']['generation'] = 'generation-2'
    channel.update!(provider_config: config)
    expect(Whatsapp::CoexistenceHistoryService).not_to receive(:new)

    described_class.perform_now(channel.id, 'history', { history: [] }, routing_context)
  end

  it 'drops a provider event created before the current synchronization generation' do
    config = channel.provider_config.deep_dup
    config['coexistence_sync']['onboarded_at'] = Time.zone.at(2_000).iso8601
    channel.update!(provider_config: config)
    expect(Whatsapp::CoexistenceHistoryService).not_to receive(:new)

    described_class.perform_now(
      channel.id,
      'history',
      { history: [] },
      routing_context.merge(provider_event_at: 1_999)
    )
  end

  it 'fails closed when the queued WABA or phone metadata no longer matches the channel' do
    expect(Whatsapp::CoexistenceHistoryService).not_to receive(:new)
    metadata = {
      phone_number_id: 'different-phone-id',
      display_phone_number: channel.phone_number.delete_prefix('+')
    }

    described_class.perform_now(channel.id, 'history', { history: [] }, routing_context(metadata: metadata))
    described_class.perform_now(
      channel.id,
      'history',
      { history: [] },
      routing_context.merge(business_account_id: 'different-waba-id')
    )
  end

  it 'revalidates metadata-free WABA ownership inside the lock and drops an ambiguous payload' do
    job = described_class.new
    allow(job).to receive(:with_lock) do |_lock_name, &block|
      sibling = create(
        :channel_whatsapp,
        provider: 'whatsapp_cloud',
        sync_templates: false,
        validate_provider_config: false
      )
      sibling.update!(
        provider_config: sibling.provider_config.merge(
          'business_account_id' => channel.provider_config['business_account_id'],
          'embedded_signup_flow' => 'coexistence'
        )
      )
      block.call
    end
    expect(Whatsapp::CoexistenceHistoryService).not_to receive(:new)

    job.perform(channel.id, 'history', { history: [] }, routing_context)
  end

  it 'uses exact phone metadata when a WABA has multiple coexistence channels' do
    sibling = create(
      :channel_whatsapp,
      provider: 'whatsapp_cloud',
      sync_templates: false,
      validate_provider_config: false
    )
    sibling.update!(
      provider_config: sibling.provider_config.merge(
        'business_account_id' => channel.provider_config['business_account_id'],
        'embedded_signup_flow' => 'coexistence'
      )
    )
    metadata = {
      phone_number_id: channel.provider_config['phone_number_id'],
      display_phone_number: channel.phone_number.delete_prefix('+')
    }
    service = instance_double(Whatsapp::CoexistenceHistoryService, perform: true)
    allow(Whatsapp::CoexistenceHistoryService).to receive(:new).and_return(service)

    described_class.perform_now(channel.id, 'history', { history: [] }, routing_context(metadata: metadata))

    expect(Whatsapp::CoexistenceHistoryService).to have_received(:new)
      .with(channel: channel, value: { history: [] }.with_indifferent_access)
  end

  it 'rejects metadata-free dispatch when a standard sibling belongs to another account' do
    standard_sibling = create(
      :channel_whatsapp,
      provider: 'whatsapp_cloud',
      sync_templates: false,
      validate_provider_config: false
    )
    standard_sibling.update!(
      provider_config: standard_sibling.provider_config.merge(
        'business_account_id' => channel.provider_config['business_account_id'],
        'embedded_signup_flow' => 'standard'
      )
    )
    expect(Whatsapp::CoexistenceHistoryService).not_to receive(:new)

    described_class.perform_now(channel.id, 'history', { history: [] }, routing_context)
  end

  it 'rejects metadata-free dispatch while a cross-account sibling is pending deletion' do
    pending_sibling = create(
      :channel_whatsapp,
      provider: 'whatsapp_cloud',
      sync_templates: false,
      validate_provider_config: false
    )
    pending_sibling.update!(
      provider_config: pending_sibling.provider_config.merge(
        'business_account_id' => channel.provider_config['business_account_id'],
        'embedded_signup_flow' => 'standard'
      )
    )
    pending_sibling.inbox.update!(deleting_at: Time.current)
    expect(Whatsapp::CoexistenceHistoryService).not_to receive(:new)

    described_class.perform_now(channel.id, 'history', { history: [] }, routing_context)
  end
end
