require 'rails_helper'

RSpec.describe Integrations::Medelement::SyncCoordinatorService do
  let(:account) { create(:account) }
  let(:hook) do
    instance_double(
      Integrations::Hook,
      id: 14,
      account_id: account.id,
      account: account,
      disabled?: false,
      feature_allowed?: true
    )
  end
  let(:configuration) do
    instance_double(
      Integrations::Medelement::Configuration,
      sync_specialists?: false,
      sync_services?: true,
      sync_patients?: false,
      sync_receptions?: false
    )
  end
  let(:client) { instance_double(Integrations::Medelement::Client) }
  let(:attribute_setup) { instance_double(Integrations::Medelement::ContactCustomAttributesSetupService, perform: true) }
  let(:services_sync) { instance_double(Integrations::Medelement::ServicesSyncService, perform: true) }

  before do
    allow(Integrations::Medelement::Configuration).to receive(:new).with(hook: hook).and_return(configuration)
    allow(Integrations::Medelement::Client).to receive(:new).with(configuration: configuration).and_return(client)
    allow(Integrations::Medelement::ContactCustomAttributesSetupService).to receive(:new).with(account: account).and_return(attribute_setup)
    allow(Integrations::Medelement::ServicesSyncService).to receive(:new).with(account: account, client: client).and_return(services_sync)
  end

  it 'runs service catalog synchronization through the regular Medelement sync boundary' do
    described_class.new(hook: hook).perform

    expect(services_sync).to have_received(:perform).once
  end

  it 'marks an unavailable optional catalog as partial and continues with later phases' do
    sync_run = instance_double(
      Integrations::Medelement::SyncRun,
      start_phase!: true,
      skip_phase!: true,
      complete_phase!: true,
      finish!: true
    )
    tracker = instance_double(Integrations::Medelement::ConflictTracker, resolve_absent!: true)
    contacts_sync = instance_double(Integrations::Medelement::LinkedContactsSyncService, perform: { selected_count: 1 })
    provider_error = Integrations::Medelement::Client::CatalogUnavailableError.new('Not found', status: 404)
    allow(configuration).to receive(:sync_patients?).and_return(true)
    allow(configuration).to receive(:organization_id).and_return('company-1')
    allow(Integrations::Medelement::ConflictTracker).to receive(:new).with(sync_run: sync_run).and_return(tracker)
    allow(Integrations::Medelement::ServicesSyncService).to receive(:new).and_return(services_sync)
    allow(Integrations::Medelement::LinkedContactsSyncService).to receive(:new).and_return(contacts_sync)
    allow(services_sync).to receive(:perform).and_raise(provider_error)

    described_class.new(hook: hook).perform(sync_run: sync_run, phases: %w[services contacts])

    expect(sync_run).to have_received(:skip_phase!).with(
      'services',
      'provider_catalog_unavailable',
      skipped_count: 1
    )
    expect(contacts_sync).to have_received(:perform)
    expect(sync_run).to have_received(:finish!)
    expect(tracker).not_to have_received(:resolve_absent!).with('services')
  end

  it 'still fails the services phase for provider errors other than not found' do
    sync_run = instance_double(
      Integrations::Medelement::SyncRun,
      start_phase!: true,
      record_phase_failure!: true
    )
    tracker = instance_double(Integrations::Medelement::ConflictTracker)
    provider_error = Integrations::Medelement::Client::ApiError.new('Forbidden', status: 403)
    allow(Integrations::Medelement::ConflictTracker).to receive(:new).with(sync_run: sync_run).and_return(tracker)
    allow(Integrations::Medelement::ServicesSyncService).to receive(:new).and_return(services_sync)
    allow(services_sync).to receive(:perform).and_raise(provider_error)

    expect do
      described_class.new(hook: hook).perform(sync_run: sync_run, phases: ['services'])
    end.to raise_error(provider_error)

    expect(sync_run).to have_received(:record_phase_failure!).with('services', provider_error)
  end

  it 'does not globally resolve contact conflicts after a bounded contact phase' do
    sync_run = instance_double(
      Integrations::Medelement::SyncRun,
      start_phase!: true,
      complete_phase!: true,
      finish!: true
    )
    tracker = instance_double(Integrations::Medelement::ConflictTracker, resolve_absent!: true)
    contacts_sync = instance_double(Integrations::Medelement::LinkedContactsSyncService, perform: { selected_count: 1 })
    allow(configuration).to receive(:sync_patients?).and_return(true)
    allow(configuration).to receive(:organization_id).and_return('company-1')
    allow(Integrations::Medelement::ConflictTracker).to receive(:new).with(sync_run: sync_run).and_return(tracker)
    allow(Integrations::Medelement::LinkedContactsSyncService).to receive(:new).and_return(contacts_sync)

    described_class.new(hook: hook).perform(sync_run: sync_run, phases: ['contacts'])

    expect(tracker).not_to have_received(:resolve_absent!)
  end
end
