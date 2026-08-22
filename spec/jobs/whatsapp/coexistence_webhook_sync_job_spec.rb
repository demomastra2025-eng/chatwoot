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
    allow(Whatsapp::WabaLivePriority).to receive(:waiting?).and_return(false)
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

  it 'retries before taking the WABA lock while live traffic is waiting' do
    job = described_class.new(channel.id, 'history', { history: [] }, routing_context)
    allow(Whatsapp::WabaLivePriority).to receive(:waiting?).and_return(true)
    expect(Whatsapp::WabaLock).not_to receive(:new)

    expect do
      job.perform_now
    end.to have_enqueued_job(described_class).on_queue('whatsappweb_history')
  end

  it 'keeps retrying lock contention after the previous retry limit' do
    job = described_class.new(channel.id, 'history', { history: [] }, routing_context)
    job.executions = 7
    lock = instance_double(Whatsapp::WabaLock)
    allow(Whatsapp::WabaLock).to receive(:new).and_return(lock)
    allow(lock).to receive(:with_lock).and_raise(Whatsapp::WabaLock::LockAcquisitionError)

    expect do
      job.perform_now
    end.to have_enqueued_job(described_class).on_queue('whatsappweb_history')
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

  it 'skips persisted ledger replay only for an internal dead-history recovery context' do
    value = { history: [] }
    service = instance_double(Whatsapp::CoexistenceHistoryService)
    reconciliation = instance_double(Whatsapp::CoexistenceSyncReconciliationService, reconcile_webhook!: true)
    job = described_class.new
    allow(job).to receive(:with_lock).and_yield
    allow(Whatsapp::CoexistenceHistoryService).to receive(:new).and_return(service)
    allow(Whatsapp::CoexistenceSyncReconciliationService).to receive(:new).with(channel).and_return(reconciliation)
    expect(service).to receive(:perform).with(replay_persisted_failures: false).and_return(true)

    job.perform(channel.id, 'history', value, routing_context.merge(skip_persisted_failure_replay: true))
  end

  it 'passes the provider envelope timestamp to contact synchronization' do
    value = { state_sync: [] }
    service = instance_double(Whatsapp::CoexistenceContactSyncService, perform: true)
    reconciliation = instance_double(Whatsapp::CoexistenceSyncReconciliationService, reconcile_webhook!: true)
    job = described_class.new
    allow(job).to receive(:with_lock).and_yield
    expect(Whatsapp::CoexistenceContactSyncService).to receive(:new)
      .with(channel: channel, value: value.with_indifferent_access, provider_event_at: 1_700_000_005)
      .and_return(service)
    allow(Whatsapp::CoexistenceSyncReconciliationService).to receive(:new).with(channel).and_return(reconciliation)

    job.perform(
      channel.id,
      'smb_app_state_sync',
      value,
      routing_context.merge(provider_event_at: 1_700_000_005)
    )

    expect(service).to have_received(:perform)
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

  it 'releases and reacquires the WABA lock between bounded history batches' do
    messages = Array.new(51) { |index| { id: "wamid.#{index}" } }
    value = { history: [{ threads: [{ id: 'contact-1', messages: messages }] }] }
    lock = instance_double(Whatsapp::WabaLock)
    service = instance_double(Whatsapp::CoexistenceHistoryService, perform: true)
    job = described_class.new
    allow(Whatsapp::WabaLock).to receive(:new).and_return(lock)
    allow(lock).to receive(:with_lock).and_yield
    allow(job).to receive(:with_lock).and_yield
    allow(Whatsapp::CoexistenceHistoryService).to receive(:new).and_return(service)

    job.perform(channel.id, 'history', value, routing_context)

    expect(lock).to have_received(:with_lock).exactly(3).times
    expect(job).to have_received(:with_lock).exactly(3).times
    expect(service).to have_received(:perform).exactly(3).times
  end

  it 'yields between batches when live traffic arrives during history import' do
    messages = Array.new(26) { |index| { id: "wamid.#{index}" } }
    value = { history: [{ threads: [{ id: 'contact-1', messages: messages }] }] }
    lock = instance_double(Whatsapp::WabaLock)
    service = instance_double(Whatsapp::CoexistenceHistoryService, perform: true)
    job = described_class.new
    allow(Whatsapp::WabaLivePriority).to receive(:waiting?).and_return(false, false, true)
    allow(Whatsapp::WabaLock).to receive(:new).and_return(lock)
    allow(lock).to receive(:with_lock).and_yield
    allow(job).to receive(:with_lock).and_yield
    allow(Whatsapp::CoexistenceHistoryService).to receive(:new).and_return(service)

    expect do
      job.perform(channel.id, 'history', value, routing_context)
    end.to raise_error(Whatsapp::WabaLivePriority::LiveTrafficPendingError)

    expect(lock).to have_received(:with_lock).once
    expect(service).to have_received(:perform).once
  end

  it 'yields inside the WABA lock when live traffic arrives after the initial check' do
    lock = instance_double(Whatsapp::WabaLock)
    job = described_class.new
    allow(Whatsapp::WabaLivePriority).to receive(:waiting?).and_return(false, true)
    allow(Whatsapp::WabaLock).to receive(:new).and_return(lock)
    allow(lock).to receive(:with_lock).and_yield
    expect(job).not_to receive(:with_lock)
    expect(Whatsapp::CoexistenceHistoryService).not_to receive(:new)

    expect do
      job.perform(channel.id, 'history', { history: [] }, routing_context)
    end.to raise_error(Whatsapp::WabaLivePriority::LiveTrafficPendingError)
  end

  it 'acquires the WABA lock before the channel lock for every batch' do
    lock = instance_double(Whatsapp::WabaLock)
    service = instance_double(Whatsapp::CoexistenceHistoryService, perform: true)
    job = described_class.new
    allow(Whatsapp::WabaLock).to receive(:new).and_return(lock)
    expect(lock).to receive(:with_lock).ordered.and_yield
    expect(job).to receive(:with_lock).ordered.and_yield
    allow(Whatsapp::CoexistenceHistoryService).to receive(:new).and_return(service)

    job.perform(channel.id, 'history', { history: [] }, routing_context)

    expect(service).to have_received(:perform).once
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
