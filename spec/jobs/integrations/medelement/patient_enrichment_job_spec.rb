require 'rails_helper'

RSpec.describe Integrations::Medelement::PatientEnrichmentJob do
  let(:account) { create(:account) }
  let(:contact) { create(:contact, account: account, phone_number: '+77000000001') }
  let(:service) { instance_double(Integrations::Medelement::PatientEnrichmentService, perform: contact) }

  before do
    account.enable_features!('scheduling')
    schedule_service = instance_double(Integrations::Medelement::CronScheduleService, sync!: true)
    allow(Integrations::Medelement::CronScheduleService).to receive(:new).and_return(schedule_service)
    allow(Integrations::Medelement::PatientEnrichmentService).to receive(:new).and_return(service)
  end

  describe '.enqueue' do
    let(:queued_job) { instance_double(described_class, successfully_enqueued?: true) }

    before do
      allow(SecureRandom).to receive(:uuid).and_return('dedup-token')
      allow(Redis::Alfred).to receive(:set).and_return(true)
      allow(described_class).to receive(:perform_later).and_return(queued_job)
    end

    it 'claims a contact-scoped lease before enqueueing' do
      expect(described_class.enqueue(13, 42)).to be(true)

      expect(Redis::Alfred).to have_received(:set).with(
        format(Redis::Alfred::MEDELEMENT_PATIENT_ENRICHMENT_QUEUED, hook_id: 13, contact_id: 42),
        'dedup-token',
        nx: true,
        ex: described_class::QUEUED_LEASE_TTL
      )
      expect(described_class).to have_received(:perform_later).with(13, 42, 'dedup-token')
    end

    it 'suppresses duplicate queued enrichment work' do
      allow(Redis::Alfred).to receive(:set).and_return(false)

      expect(described_class.enqueue(13, 42)).to be(false)
      expect(described_class).not_to have_received(:perform_later)
    end

    it 'releases the lease when enqueueing fails' do
      allow(Redis::Alfred).to receive(:delete_if_value)
      allow(described_class).to receive(:perform_later).and_return(false)

      expect { described_class.enqueue(13, 42) }.to raise_error(ActiveJob::EnqueueError)
      expect(Redis::Alfred).to have_received(:delete_if_value).with(
        format(Redis::Alfred::MEDELEMENT_PATIENT_ENRICHMENT_QUEUED, hook_id: 13, contact_id: 42),
        'dedup-token'
      )
    end
  end

  it 'releases its queued lease before processing' do
    hook = create(:integrations_hook, :medelement, account: account)
    job = described_class.new
    allow(job).to receive(:with_lock).and_yield
    allow(Redis::Alfred).to receive(:delete_if_value)

    job.perform(hook.id, contact.id, 'dedup-token')

    expect(Redis::Alfred).to have_received(:delete_if_value).with(
      format(Redis::Alfred::MEDELEMENT_PATIENT_ENRICHMENT_QUEUED, hook_id: hook.id, contact_id: contact.id),
      'dedup-token'
    )
  end

  it 'enriches an account-scoped contact under a contact-scoped lock' do
    hook = create(:integrations_hook, :medelement, account: account)
    job = described_class.new
    allow(job).to receive(:with_lock).and_yield

    job.perform(hook.id, contact.id)

    expect(job).to have_received(:with_lock).with(
      format(
        Redis::Alfred::MEDELEMENT_PATIENT_ENRICHMENT_MUTEX,
        hook_id: hook.id,
        contact_id: contact.id
      ),
      described_class::LOCK_TIMEOUT
    )
    expect(service).to have_received(:perform).with(contact)
  end

  it 'skips disabled hooks' do
    hook = create(:integrations_hook, :medelement, account: account, status: 'disabled')
    job = described_class.new
    allow(job).to receive(:with_lock)

    job.perform(hook.id, contact.id)

    expect(job).not_to have_received(:with_lock)
    expect(service).not_to have_received(:perform)
  end

  it 'skips enrichment when patient synchronization is disabled' do
    settings = attributes_for(:integrations_hook, :medelement)[:settings].merge('sync_patients' => false)
    hook = create(:integrations_hook, :medelement, account: account, settings: settings)
    job = described_class.new
    allow(job).to receive(:with_lock)

    job.perform(hook.id, contact.id)

    expect(job).not_to have_received(:with_lock)
    expect(service).not_to have_received(:perform)
  end

  it 'skips unsupported phone numbers without an API call' do
    hook = create(:integrations_hook, :medelement, account: account)
    contact.update!(phone_number: '+998000000001')
    job = described_class.new
    allow(job).to receive(:with_lock)

    job.perform(hook.id, contact.id)

    expect(job).not_to have_received(:with_lock)
    expect(service).not_to have_received(:perform)
  end

  it 'does not retry a provider validation response' do
    hook = create(:integrations_hook, :medelement, account: account)
    error = Integrations::Medelement::Client::ApiError.new('rejected', status: 422)
    allow(service).to receive(:perform).and_raise(error)
    allow(Rails.logger).to receive(:warn)
    job = described_class.new
    allow(job).to receive(:with_lock).and_yield

    expect { job.perform(hook.id, contact.id) }.not_to raise_error
    expect(Rails.logger).to have_received(:warn).with('Medelement patient enrichment rejected with HTTP 422')
  end

  it 're-raises retryable read failures for bounded ActiveJob retry' do
    hook = create(:integrations_hook, :medelement, account: account)
    error = Integrations::Medelement::Client::ApiError.new('temporary', status: 503)
    allow(service).to receive(:perform).and_raise(error)
    job = described_class.new
    allow(job).to receive(:with_lock).and_yield

    expect { job.perform(hook.id, contact.id) }.to raise_error(error)
  end
end
