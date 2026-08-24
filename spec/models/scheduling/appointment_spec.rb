require 'rails_helper'

RSpec.describe Scheduling::Appointment do
  describe 'contact owner sync' do
    let(:account) { create(:account) }
    let(:owner) { create(:user, account: account, role: :agent) }
    let(:new_owner) { create(:user, account: account, role: :agent) }
    let(:contact) { create(:contact, account: account, owner: owner) }

    it 'inherits the contact owner on create' do
      appointment = create(:scheduling_appointment, account: account, contact: contact, owner: nil)

      expect(appointment.owner).to eq(owner)
    end

    it 'inherits the linked resource user when the contact has no owner' do
      resource_owner = create(:user, account: account, role: :agent)
      resource = create(:scheduling_resource, account: account, user: resource_owner)
      unowned_contact = create(:contact, account: account, owner: nil)

      appointment = create(:scheduling_appointment, account: account, contact: unowned_contact, resource: resource, owner: nil)

      expect(appointment.owner).to eq(resource_owner)
      expect(unowned_contact.reload.owner).to eq(resource_owner)
    end

    it 'syncs owner changes back to the contact' do
      appointment = create(:scheduling_appointment, account: account, contact: contact, owner: owner)

      appointment.update!(owner: new_owner)

      expect(contact.reload.owner).to eq(new_owner)
    end

    it 'allows clearing the owner and clears the contact owner' do
      appointment = create(:scheduling_appointment, account: account, contact: contact, owner: owner)

      appointment.update!(owner: nil)

      expect(contact.reload.owner).to be_nil
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

    it 'dispatches appointment.completed when status changes to completed' do
      captured_events = []
      allow(Rails.configuration.dispatcher).to receive(:dispatch) do |event_name, _, data|
        captured_events << [event_name, data]
      end

      appointment.update!(status: 'completed')

      expect(captured_events.map(&:first)).to include(Events::Types::APPOINTMENT_UPDATED, Events::Types::APPOINTMENT_COMPLETED)
    end
  end
end
