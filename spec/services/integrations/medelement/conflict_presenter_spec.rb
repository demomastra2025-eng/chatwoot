require 'rails_helper'

describe Integrations::Medelement::ConflictPresenter do
  let(:account) { create(:account) }
  let(:hook) { create(:integrations_hook, :medelement, account: account) }
  let(:run) do
    Integrations::Medelement::SyncRun.create!(account: account, hook: hook, trigger: 'manual', status: 'partial')
  end
  let(:primary_contact) { create(:contact, account: account) }
  let(:conflicting_contact) { create(:contact, account: account) }

  before { account.enable_features!('scheduling') }

  def conflict_with(details)
    Integrations::Medelement::ConflictTracker.new(sync_run: run).record!(
      phase: 'contacts',
      entity_type: 'contact',
      conflict_type: 'phone_owned_by_another_contact',
      entity_key: 'patient-1',
      details: details
    )
  end

  it 'allows destructive actions only when the conflicting contact is immutable conflict evidence' do
    conflict = conflict_with(
      contact_id: primary_contact.id,
      conflicting_contact_id: conflicting_contact.id
    )

    resolution = described_class.new(conflict: conflict).payload[:contact_resolution]

    expect(resolution).to include(
      can_merge: true,
      primary_contact: hash_including(id: primary_contact.id),
      conflicting_contact: hash_including(id: conflicting_contact.id)
    )
  end

  it 'shows the legacy conflicting contact but does not allow destructive actions' do
    primary_contact.update!(custom_attributes: {
                              'phone_conflict_comment' => "Phone already belongs to contact ##{conflicting_contact.id}"
                            })
    conflict = conflict_with(contact_id: primary_contact.id)

    resolution = described_class.new(conflict: conflict).payload[:contact_resolution]

    expect(resolution).to include(
      can_merge: false,
      can_delete_conflicting: false,
      primary_contact: hash_including(id: primary_contact.id),
      conflicting_contact: hash_including(id: conflicting_contact.id)
    )
  end

  it 'shows important OneLink and MedElement fields for a phone mismatch' do
    hook.update!(settings: hook.settings.merge('write_enabled' => true))
    primary_contact.update!(
      name: 'Local name',
      phone_number: '+77010007777',
      identifier: '950424301111',
      custom_attributes: {
        'medelement_patient_code' => 'patient-1',
        'medelement_first_name' => 'Provider name',
        'medelement_iin' => '950424309911',
        'address' => 'Local address',
        'medelement_address' => 'Provider address',
        'phone_conflict_comment' => 'Medelement phone +77010007060 differs from the current Contact phone'
      }
    )
    conflict = Integrations::Medelement::ConflictTracker.new(sync_run: run).record!(
      phase: 'contacts',
      entity_type: 'contact',
      conflict_type: 'phone_mismatch',
      entity_key: 'patient-1',
      details: { contact_id: primary_contact.id }
    )

    resolution = described_class.new(conflict: conflict).payload[:contact_resolution]

    expect(resolution[:can_sync_fields]).to be(true)
    expect(resolution[:field_comparisons]).to include(
      hash_including(
        field: :first_name,
        onelink_value: 'Local name',
        medelement_value: 'Provider name',
        differs: true,
        can_sync_to_medelement: true
      ),
      hash_including(field: :phone, onelink_value: '+77010007777', medelement_value: '+77010007060', differs: true),
      hash_including(field: :iin, differs: true),
      hash_including(field: :address, differs: true, can_sync_to_onelink: true, can_sync_to_medelement: false)
    )
  end

  it 'presents an account-scoped specialist card' do
    resource = create(
      :scheduling_resource,
      account: account,
      name: 'Doctor One',
      specialty: 'Cardiology',
      custom_attributes: { 'medelement_specialist_code' => 'specialist-1' }
    )
    conflict = Integrations::Medelement::ConflictTracker.new(sync_run: run).record!(
      phase: 'specialists',
      entity_type: 'specialist',
      conflict_type: 'invalid_specialist',
      entity_key: 'specialist-1',
      details: { resource_id: resource.id, specialist_code: 'specialist-1' }
    )

    context = described_class.new(conflict: conflict).payload[:entity_context]

    expect(context).to include(
      kind: 'specialist',
      specialist_code: 'specialist-1',
      specialty: 'Cardiology',
      resource: hash_including(id: resource.id, name: 'Doctor One')
    )
  end

  it 'presents an account-scoped appointment card with financial conflict values' do
    appointment = create(
      :scheduling_appointment,
      account: account,
      source: 'medelement',
      external_ref: 'medelement:reception:reception-1',
      custom_attributes: {
        'medelement_reception_code' => 'reception-1',
        'medelement_specialist_code' => 'specialist-1'
      }
    )
    conflict = Integrations::Medelement::ConflictTracker.new(sync_run: run).record!(
      phase: 'receptions',
      entity_type: 'appointment',
      conflict_type: 'appointment_amount_mismatch',
      entity_key: 'reception-1',
      details: { reception_code: 'reception-1', local_amount: 1000, provider_amount: 1200 }
    )

    context = described_class.new(conflict: conflict).payload[:entity_context]

    expect(context).to include(
      kind: 'appointment',
      reception_code: 'reception-1',
      specialist_code: 'specialist-1',
      local_amount: 1000,
      provider_amount: 1200,
      appointment: hash_including(id: appointment.id, client_name: appointment.client_name)
    )
  end

  it 'shows the account-scoped specialist for a legacy invalid reception without an appointment' do
    resource = create(:scheduling_resource, account: account, name: 'Legacy Doctor')
    conflict = Integrations::Medelement::ConflictTracker.new(sync_run: run).record!(
      phase: 'receptions',
      entity_type: 'reception',
      conflict_type: 'invalid_reception',
      entity_key: 'legacy-reception',
      details: { resource_id: resource.id }
    )

    context = described_class.new(conflict: conflict).payload[:entity_context]

    expect(context).to include(kind: 'appointment', resource: hash_including(id: resource.id, name: 'Legacy Doctor'))
  end

  it 'does not resolve specialist records across accounts' do
    other_account = create(:account)
    other_account.enable_features!('scheduling')
    other_resource = create(:scheduling_resource, account: other_account)
    conflict = Integrations::Medelement::ConflictTracker.new(sync_run: run).record!(
      phase: 'specialists',
      entity_type: 'specialist',
      conflict_type: 'invalid_specialist',
      entity_key: 'foreign-specialist',
      details: { resource_id: other_resource.id, specialist_code: 'foreign-specialist' }
    )

    context = described_class.new(conflict: conflict).payload[:entity_context]

    expect(context[:resource]).to be_nil
  end

  it 'does not resolve appointment records across accounts' do
    other_account = create(:account)
    other_account.enable_features!('scheduling')
    other_appointment = create(
      :scheduling_appointment,
      account: other_account,
      external_ref: 'medelement:reception:foreign-reception'
    )
    conflict = Integrations::Medelement::ConflictTracker.new(sync_run: run).record!(
      phase: 'receptions',
      entity_type: 'appointment',
      conflict_type: 'appointment_amount_mismatch',
      entity_key: 'foreign-reception',
      details: { appointment_id: other_appointment.id, reception_code: 'foreign-reception' }
    )

    context = described_class.new(conflict: conflict).payload[:entity_context]

    expect(context[:appointment]).to be_nil
  end

  it 'ignores invalid provider epoch values instead of rendering misleading dates' do
    conflict = Integrations::Medelement::ConflictTracker.new(sync_run: run).record!(
      phase: 'receptions',
      entity_type: 'reception',
      conflict_type: 'invalid_reception',
      entity_key: 'invalid-provider-time',
      details: { starts_at_unix: 'not-a-time', ends_at_unix: 9_999_999_999_999 }
    )

    context = described_class.new(conflict: conflict).payload[:entity_context]

    expect(context).not_to include(:starts_at, :ends_at)
  end
end
