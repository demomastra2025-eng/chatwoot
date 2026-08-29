require 'rails_helper'

RSpec.describe Integrations::Medelement::SyncCoordinatorService do
  let(:account) { create(:account) }
  let(:hook) do
    instance_double(
      Integrations::Hook,
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
