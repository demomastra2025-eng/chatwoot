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

  it 'passes the configured provider organization to the contact resolver' do
    allow(resolver).to receive(:sync_patient!).with('patient-1', preferred_contact: contact).and_return(contact)

    described_class.new(
      account: account,
      client: client,
      conflict_tracker: conflict_tracker,
      organization_id: 'company-1'
    ).perform

    expect(Integrations::Medelement::ContactResolverService).to have_received(:new).with(
      account: account,
      client: client,
      conflict_tracker: conflict_tracker,
      organization_id: 'company-1'
    )
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

  it 'skips a forbidden linked patient only when it is absent from the allowed provider scope' do
    second_contact = create(
      :contact,
      account: account,
      custom_attributes: { 'medelement_patient_code' => 'patient-2' }
    )
    provider_error = Integrations::Medelement::Client::ApiError.new('Forbidden', status: 403)
    allow(resolver).to receive(:sync_patient!).with('patient-1', preferred_contact: contact).and_raise(provider_error)
    allow(resolver).to receive(:sync_patient!).with('patient-2', preferred_contact: second_contact).and_return(second_contact)
    allow(client).to receive(:search_patients_by_codes).with(patient_codes: ['patient-1']).and_return([])

    result = described_class.new(account: account, client: client, conflict_tracker: conflict_tracker).perform

    expect(result).to eq(linked_count: 2, synced_count: 1, skipped_count: 1)
    expect(conflict_tracker).to have_received(:record!).with(
      hash_including(
        conflict_type: 'patient_not_found',
        entity_key: 'patient-1',
        details: hash_including(reason: 'Provider denied linked patient and code search returned no patient')
      )
    )
  end

  it 'does not hide a forbidden response when code search can still see the patient' do
    provider_error = Integrations::Medelement::Client::ApiError.new('Forbidden', status: 403)
    allow(resolver).to receive(:sync_patient!).and_raise(provider_error)
    allow(client).to receive(:search_patients_by_codes).with(patient_codes: ['patient-1']).and_return(
      [{ 'PROFILE_CODE' => 'patient-1' }]
    )

    expect do
      described_class.new(account: account, client: client, conflict_tracker: conflict_tracker).perform
    end.to raise_error(Integrations::Medelement::Client::ApiError, 'Forbidden')
  end

  it 'does not search when the forbidden patient code is blank' do
    provider_error = Integrations::Medelement::Client::ApiError.new('Forbidden', status: 403)
    contact.update!(custom_attributes: { 'medelement_patient_code' => '' })
    allow(resolver).to receive(:sync_patient!).and_raise(provider_error)

    expect(client).not_to receive(:search_patients_by_codes)
    expect do
      described_class.new(account: account, client: client, conflict_tracker: conflict_tracker).perform
    end.to raise_error(Integrations::Medelement::Client::ApiError, 'Forbidden')
  end

  it 'preserves the forbidden response when code search fails' do
    provider_error = Integrations::Medelement::Client::ApiError.new('Forbidden', status: 403)
    search_error = Integrations::Medelement::Client::ApiError.new('Search failed', status: 500)
    allow(resolver).to receive(:sync_patient!).and_raise(provider_error)
    allow(client).to receive(:search_patients_by_codes).with(patient_codes: ['patient-1']).and_raise(search_error)

    matcher = raise_error { |error| expect(error).to equal(provider_error) }
    expect do
      described_class.new(account: account, client: client, conflict_tracker: conflict_tracker).perform
    end.to matcher
  end
end
