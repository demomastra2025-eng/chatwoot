require 'rails_helper'

RSpec.describe Integrations::Medelement::LinkedContactsSyncService do
  let(:account) { create(:account) }
  let(:contact) do
    create(
      :contact,
      account: account,
      custom_attributes: { 'medelement_patient_code' => 'patient-1' }
    )
  end
  let(:client) { instance_double(Integrations::Medelement::Client) }
  let(:resolver) { instance_double(Integrations::Medelement::ContactResolverService) }
  let(:conflict_tracker) { instance_double(Integrations::Medelement::ConflictTracker, record!: true) }

  before do
    contact
    allow(Integrations::Medelement::ContactResolverService).to receive(:new).and_return(resolver)
  end

  it 'force-refreshes every linked contact through its provider patient code' do
    allow(resolver).to receive(:sync_patient!).with('patient-1', preferred_contact: contact).and_return(contact)

    result = described_class.new(account: account, client: client, conflict_tracker: conflict_tracker).perform

    expect(result).to eq(linked_count: 1, synced_count: 1, skipped_count: 0)
    expect(conflict_tracker).not_to have_received(:record!)
  end

  it 'records a patient-not-found conflict without aborting the batch' do
    allow(resolver).to receive(:sync_patient!).and_return(nil)

    result = described_class.new(account: account, client: client, conflict_tracker: conflict_tracker).perform

    expect(result).to eq(linked_count: 1, synced_count: 0, skipped_count: 1)
    expect(conflict_tracker).to have_received(:record!).with(
      hash_including(
        phase: 'contacts',
        entity_type: 'contact',
        conflict_type: 'patient_not_found',
        entity_key: 'patient-1'
      )
    )
  end
end
