require 'rails_helper'

RSpec.describe Scheduling::Appointment do
  describe 'reminder ownership' do
    let(:account) { create(:account) }
    let(:owner) { create(:user, account: account, role: :agent) }
    let(:new_owner) { create(:user, account: account, role: :agent) }
    let(:contact) { create(:contact, account: account, owner: owner) }

    it 'resolves the contact owner even when the legacy column disagrees' do
      appointment = create(:scheduling_appointment, account: account, contact: contact, owner_id: new_owner.id)

      expect(appointment.reminder_owner).to eq(owner)
      expect(appointment.reload.owner_id).to eq(new_owner.id)
      expect(contact.reload.owner).to eq(owner)
    end

    it 'uses the creator, not the specialist, when the contact has no owner' do
      resource_owner = create(:user, account: account, role: :agent)
      resource = create(:scheduling_resource, account: account, user: resource_owner)
      unowned_contact = create(:contact, account: account, owner: nil)

      appointment = create(:scheduling_appointment, account: account, contact: unowned_contact, resource: resource,
                                                    created_by: new_owner)

      expect(appointment.reminder_owner).to eq(new_owner)
      expect(unowned_contact.reload.owner).to be_nil
    end

    it 'does not sync writes to the historical column back to the contact' do
      appointment = create(:scheduling_appointment, account: account, contact: contact)

      appointment.update!(owner_id: new_owner.id)

      expect(contact.reload.owner).to eq(owner)
      expect(appointment.reminder_owner).to eq(owner)
    end

    it 'resyncs an open reminder after a direct contact rebind' do
      replacement = create(:contact, account: account, owner: new_owner)
      appointment = create(:scheduling_appointment, account: account, contact: contact, created_by: owner)
      reminder = create(:reminder, account: account, remindable: appointment, body: 'Visit', scheduled_at: 2.days.from_now)

      appointment.update!(contact: replacement)

      expect(reminder.reload).to have_attributes(owner_id: new_owner.id, target_contact_id: replacement.id)
    end

    it 'resyncs an unmaterialized processing reminder after a direct contact rebind' do
      replacement = create(:contact, account: account, owner: new_owner)
      original_conversation = create(:conversation, account: account, contact: contact)
      replacement_conversation = create(:conversation, account: account, contact: replacement, inbox: original_conversation.inbox)
      appointment = create(:scheduling_appointment, account: account, contact: contact,
                                                    conversation: original_conversation, created_by: owner)
      reminder = create(:reminder, account: account, remindable: appointment, touch_conversation: original_conversation,
                                   body: 'Visit', scheduled_at: 2.days.from_now)
      expect(reminder.reload).to be_pending
      claim = reminder.mark_processing!
      expect(reminder.reload).to have_attributes(
        status: 'processing', owner_id: owner.id, target_contact_id: contact.id,
        target_conversation_id: original_conversation.id
      )

      appointment.update!(contact: replacement, conversation: replacement_conversation)

      expect(reminder.reload).to have_attributes(
        owner_id: new_owner.id, target_contact_id: replacement.id,
        target_conversation_id: replacement_conversation.id, status: 'processing'
      )
      expect(reminder.processing_claim_token).to eq(claim)
    end

    it 'leaves the materialized delivery addressed to its original contact after a direct rebind' do
      replacement = create(:contact, account: account, owner: new_owner)
      appointment = create(:scheduling_appointment, account: account, contact: contact)
      reminder = create(:reminder, account: account, remindable: appointment,
                                   body: 'Already sent', scheduled_at: 2.days.from_now)
      reminder.mark_processing!
      reminder.mark_delivery_materialized!(123)
      original = reminder.reload.attributes.slice('owner_id', 'target_contact_id', 'target_conversation_id', 'metadata')

      appointment.update!(contact: replacement)

      expect(reminder.reload.attributes.slice(*original.keys)).to eq(original)
      expect(reminder).to be_processing
    end
  end

  describe 'automation events' do
    let(:appointment) { create(:scheduling_appointment) }

    it 'dispatches appointment.created after create' do
      captured_events = []

      allow(Rails.configuration.dispatcher).to receive(:dispatch) do |event_name, _, data|
        captured_events << [event_name, data]
      end

      create(:scheduling_appointment)

      expect(captured_events.map(&:first)).to include(Events::Types::APPOINTMENT_CREATED)
      event_data = captured_events.find { |event_name, _| event_name == Events::Types::APPOINTMENT_CREATED }.last
      expect(event_data[:appointment]).to be_a(described_class)
    end

    it 'dispatches appointment.updated with changed attributes after update' do
      captured_events = []
      allow(Rails.configuration.dispatcher).to receive(:dispatch) do |event_name, _, data|
        captured_events << [event_name, data]
      end

      appointment.update!(client_name: 'Updated Client')

      updated_event = captured_events.find { |event_name, _| event_name == Events::Types::APPOINTMENT_UPDATED }
      expect(updated_event).to be_present
      expect(updated_event.last[:changed_attributes]).to include('client_name')
    end

    it 'captures the outbound snapshot before the async dispatcher boundary' do
      Current.executed_by = create(:user, account: appointment.account)
      captured_events = []
      allow(Rails.configuration.dispatcher).to receive(:dispatch) do |event_name, _, data|
        captured_events << [event_name, data]
      end

      appointment.update!(client_name: 'Event Client')

      updated_event = captured_events.find { |event_name, _| event_name == Events::Types::APPOINTMENT_UPDATED }
      expect(updated_event.last[:medelement_outbound_snapshot]).to include(
        'client_name' => 'Event Client',
        Integrations::Medelement::OutboundChangeService::CONTACT_SNAPSHOT_KEY => anything
      )
    ensure
      Current.reset
    end

    it 'captures the outbound snapshot for a Captain appointment mutation' do
      Current.executed_by = create(:captain_assistant, account: appointment.account)
      captured_events = []
      allow(Rails.configuration.dispatcher).to receive(:dispatch) do |event_name, _, data|
        captured_events << [event_name, data]
      end

      appointment.update!(client_name: 'Captain Client')

      updated_event = captured_events.find { |event_name, _| event_name == Events::Types::APPOINTMENT_UPDATED }
      expect(updated_event.last[:medelement_outbound_snapshot]).to include(
        'client_name' => 'Captain Client',
        Integrations::Medelement::OutboundChangeService::CONTACT_SNAPSHOT_KEY => anything
      )
    ensure
      Current.reset
    end

    it 'does not capture an outbound snapshot for a Captain assistant from another account' do
      Current.executed_by = create(:captain_assistant, account: create(:account))
      captured_events = []
      allow(Rails.configuration.dispatcher).to receive(:dispatch) do |event_name, _, data|
        captured_events << [event_name, data]
      end

      appointment.update!(client_name: 'Cross-account Captain')

      updated_event = captured_events.find { |event_name, _| event_name == Events::Types::APPOINTMENT_UPDATED }
      expect(updated_event.last[:medelement_outbound_snapshot]).to be_nil
    ensure
      Current.reset
    end

    it 'dispatches appointment.cancelled when status changes to cancelled' do
      captured_events = []
      allow(Rails.configuration.dispatcher).to receive(:dispatch) do |event_name, _, data|
        captured_events << [event_name, data]
      end

      appointment.update!(status: 'cancelled')

      expect(captured_events.map(&:first)).to include(Events::Types::APPOINTMENT_UPDATED, Events::Types::APPOINTMENT_CANCELLED)
      source_versions = captured_events.filter_map do |event_name, data|
        data[:medelement_source_updated_at] if event_name.in?([Events::Types::APPOINTMENT_UPDATED, Events::Types::APPOINTMENT_CANCELLED])
      end
      expect(source_versions).to contain_exactly(appointment.updated_at.utc.iso8601(6), appointment.updated_at.utc.iso8601(6))
    end

    it 'captures provider reconciliation provenance on tombstone events' do
      Current.executed_by = create(:user, account: appointment.account)
      captured_events = []
      allow(Rails.configuration.dispatcher).to receive(:dispatch) do |event_name, _, data|
        captured_events << [event_name, data]
      end

      appointment.mark_medelement_provider_reconciled!
      appointment.update!(
        status: 'cancelled',
        custom_attributes: appointment.custom_attributes.merge(
          'medelement_reception_code' => 'provider-removed',
          'source_mode' => 'provider_tombstone'
        )
      )

      tombstone_events = captured_events.to_h
                                        .slice(Events::Types::APPOINTMENT_UPDATED, Events::Types::APPOINTMENT_CANCELLED)
                                        .values
      expect(tombstone_events).to all(include(medelement_provider_reconciled: true))

      captured_events.clear
      appointment.update!(status: 'scheduled')
      reopened_event = captured_events.find { |event_name, _| event_name == Events::Types::APPOINTMENT_UPDATED }
      expect(reopened_event.last[:medelement_provider_reconciled]).to be(false)

      appointment.update!(status: 'cancelled')
      expect(appointment.custom_attributes['medelement_local_cancelled_at']).to be_present
    ensure
      Current.reset
    end

    it 'preserves coalesced changes and provider provenance until legacy commit dispatch' do
      captured_events = []
      allow(Rails.configuration.dispatcher).to receive(:dispatch) do |event_name, _, data|
        captured_events << [event_name, data]
      end

      appointment.mark_medelement_provider_reconciled!
      described_class.transaction do
        appointment.update!(client_name: 'Provider Client')
        appointment.update!(status: 'cancelled')
      end

      updated_event = captured_events.find { |event_name, _| event_name == Events::Types::APPOINTMENT_UPDATED }
      expect(updated_event.last[:changed_attributes].keys).to include('client_name', 'status')
      expect(updated_event.last[:medelement_provider_reconciled]).to be(true)
    end

    it 'clears create-transaction update state before a later update' do
      captured_events = []
      allow(Rails.configuration.dispatcher).to receive(:dispatch) do |event_name, _, data|
        captured_events << [event_name, data]
      end

      created_appointment = nil
      described_class.transaction do
        created_appointment = create(:scheduling_appointment)
        created_appointment.mark_medelement_provider_reconciled!
        created_appointment.update!(client_name: 'Updated During Create')
      end

      durable_events = AutomationEvent.where(
        subject_type: described_class.base_class.name,
        subject_id: created_appointment.id
      )
      created_event = durable_events.find_by!(event_name: 'appointment_created')
      expect(created_event).to be_present
      transient_state = %i[
        @updated_changes_for_commit @medelement_provider_reconciled
        @automation_create_occurrence_id @automation_update_occurrence_id
      ].map { |name| created_appointment.instance_variable_get(name) }
      expect(transient_state).to all(be_nil)

      captured_events.clear
      created_appointment.update!(status: 'cancelled')

      updated_event = captured_events.find { |event_name, _| event_name == Events::Types::APPOINTMENT_UPDATED }
      expect(updated_event.last[:changed_attributes].keys).to contain_exactly('status')
      expect(updated_event.last[:medelement_provider_reconciled]).to be(false)

      durable_update = durable_events.find_by!(event_name: 'appointment_updated')
      expect(durable_update.changes_snapshot.keys).to contain_exactly('status')
      expect(durable_update.dedupe_key.split(':').last).not_to eq(created_event.dedupe_key.split(':').last)
    end

    it 'dispatches appointment.completed when status changes to completed' do
      captured_events = []
      allow(Rails.configuration.dispatcher).to receive(:dispatch) do |event_name, _, data|
        captured_events << [event_name, data]
      end

      appointment.update!(status: 'completed')

      expect(captured_events.map(&:first)).to include(Events::Types::APPOINTMENT_UPDATED, Events::Types::APPOINTMENT_COMPLETED)
    end
  end

  describe 'scheduling scope invalidation' do
    it 'invalidates the account scope after destroy' do
      appointment = create(:scheduling_appointment)
      allow(Scheduling::ScopeInvalidation).to receive(:dispatch)

      appointment.destroy!

      expect(Scheduling::ScopeInvalidation).to have_received(:dispatch).with(appointment.account)
    end
  end
end
