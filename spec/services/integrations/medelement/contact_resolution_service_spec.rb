require 'rails_helper'

describe Integrations::Medelement::ContactResolutionService do
  subject(:service) { described_class.new(conflict: conflict, user: admin) }

  let(:account) { create(:account) }
  let(:admin) { create(:user, account: account, role: :administrator) }
  let(:hook) { create(:integrations_hook, :medelement, account: account) }
  let(:run) do
    Integrations::Medelement::SyncRun.create!(account: account, hook: hook, trigger: 'manual', status: 'partial')
  end
  let(:primary_contact) do
    create(:contact, account: account, custom_attributes: { 'medelement_patient_code' => 'patient-1' })
  end
  let(:conflicting_contact) { create(:contact, account: account) }
  let(:conflict) do
    Integrations::Medelement::ConflictTracker.new(sync_run: run).record!(
      phase: 'contacts',
      entity_type: 'contact',
      conflict_type: 'phone_owned_by_another_contact',
      entity_key: 'patient-1',
      details: {
        contact_id: primary_contact.id,
        conflicting_contact_id: conflicting_contact.id,
        reason: 'Phone ownership conflict'
      }
    )
  end

  before { account.enable_features!('scheduling') }

  describe '#keep_separate!' do
    it 'resolves the conflict with the administrator note' do
      service.keep_separate!(note: 'Shared family number')

      expect(conflict.reload).to have_attributes(
        status: 'ignored',
        resolved_by: admin,
        resolution_note: 'Shared family number'
      )
    end

    it 'requires a non-empty note' do
      expect { service.keep_separate!(note: ' ') }.to raise_error(ArgumentError, 'Resolution note is required')
    end
  end

  describe '#delete!' do
    it 'deletes an empty conflict contact and resolves the conflict' do
      service.delete!(contact_id: conflicting_contact.id)

      expect(Contact.exists?(conflicting_contact.id)).to be(false)
      expect(conflict.reload).to be_resolved
    end

    it 'rejects deletion when the contact is referenced by a message' do
      create(:message, sender: conflicting_contact)

      expect do
        service.delete!(contact_id: conflicting_contact.id)
      end.to raise_error(described_class::UnsafeDeletionError)
      expect(conflicting_contact.reload).to be_present
      expect(conflict.reload).to be_open
    end

    it 'rolls back contact deletion when resolving the conflict fails' do
      allow(conflict).to receive(:update!).and_raise(ActiveRecord::RecordInvalid)

      expect { service.delete!(contact_id: conflicting_contact.id) }.to raise_error(ActiveRecord::RecordInvalid)

      expect(conflicting_contact.reload).to be_present
      expect(conflict.reload).to be_open
    end
  end

  describe '#merge_contacts!' do
    it 'merges only the two contacts recorded in the conflict' do
      appointment = create(:scheduling_appointment, account: account, contact: conflicting_contact)

      service.merge_contacts!(base_contact_id: primary_contact.id, mergee_contact_id: conflicting_contact.id)

      expect(appointment.reload.contact_id).to eq(primary_contact.id)
      expect(Contact.exists?(conflicting_contact.id)).to be(false)
      expect(conflict.reload).to have_attributes(status: 'resolved', resolved_by: admin)
    end

    it 'rejects a same-account contact that is not part of the conflict' do
      unrelated = create(:contact, account: account)

      expect do
        service.merge_contacts!(base_contact_id: primary_contact.id, mergee_contact_id: unrelated.id)
      end.to raise_error(ActiveRecord::RecordNotFound)
    end

    it 'rejects reversing the recorded merge direction' do
      expect do
        service.merge_contacts!(base_contact_id: conflicting_contact.id, mergee_contact_id: primary_contact.id)
      end.to raise_error(ActiveRecord::RecordNotFound)

      expect(primary_contact.reload).to be_present
      expect(conflicting_contact.reload).to be_present
      expect(conflict.reload).to be_open
    end

    it 'rolls back the contact merge when resolving the conflict fails' do
      allow(conflict).to receive(:update!).and_raise(ActiveRecord::RecordInvalid)

      expect do
        service.merge_contacts!(base_contact_id: primary_contact.id, mergee_contact_id: conflicting_contact.id)
      end.to raise_error(ActiveRecord::RecordInvalid)

      expect(primary_contact.reload).to be_present
      expect(conflicting_contact.reload).to be_present
      expect(conflict.reload).to be_open
    end

    it 'rejects a legacy conflicting contact id that is not immutable conflict evidence' do
      conflict.update!(details: { 'contact_id' => primary_contact.id })
      primary_contact.update!(custom_attributes: {
                                'medelement_patient_code' => 'patient-1',
                                'phone_conflict_comment' => "Phone already belongs to contact ##{conflicting_contact.id}"
                              })

      expect do
        service.merge_contacts!(base_contact_id: primary_contact.id, mergee_contact_id: conflicting_contact.id)
      end.to raise_error(ActiveRecord::RecordNotFound)

      expect(primary_contact.reload).to be_present
      expect(conflicting_contact.reload).to be_present
      expect(conflict.reload).to be_open
    end

    it 'does not follow a changed legacy contact comment' do
      unrelated = create(:contact, account: account)
      conflict.update!(details: { 'contact_id' => primary_contact.id })
      primary_contact.update!(custom_attributes: {
                                'medelement_patient_code' => 'patient-1',
                                'phone_conflict_comment' => "Phone already belongs to contact ##{unrelated.id}"
                              })

      expect do
        service.merge_contacts!(base_contact_id: primary_contact.id, mergee_contact_id: unrelated.id)
      end.to raise_error(ActiveRecord::RecordNotFound)

      expect(unrelated.reload).to be_present
      expect(conflict.reload).to be_open
    end
  end
end
