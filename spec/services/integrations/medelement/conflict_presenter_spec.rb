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
end
