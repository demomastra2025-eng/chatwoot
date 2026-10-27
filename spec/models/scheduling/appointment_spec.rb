require 'rails_helper'

RSpec.describe Scheduling::Appointment do
  describe 'duration limits' do
    let(:starts_at) { Time.zone.parse('2026-03-21 09:00:00') }

    it 'accepts a 24 hour duration and rejects a duration above 24 hours' do
      appointment = build(
        :scheduling_appointment,
        starts_at: starts_at,
        ends_at: starts_at + 24.hours,
        duration_min: Scheduling::Constants::MAX_DURATION_MINUTES
      )

      expect(appointment).to be_valid

      appointment.duration_min = Scheduling::Constants::MAX_DURATION_MINUTES + 1

      expect(appointment).not_to be_valid
      expect(appointment.errors.attribute_names).to include(:duration_min)
    end

    it 'continues rejecting a non-positive appointment interval' do
      appointment = build(:scheduling_appointment, starts_at: starts_at, ends_at: starts_at)

      expect(appointment).not_to be_valid
      expect(appointment.errors.attribute_names).to include(:ends_at)
    end
  end

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

    it 'keeps a local-only MedElement cancellation apart from the removal marker and drops it when re-opened' do
      marker_key = Integrations::Medelement::LocalCancellation::MARKER_KEY
      appointment.update!(custom_attributes: appointment.custom_attributes.merge('medelement_reception_code' => 'reception-1'))

      appointment.update!(
        status: 'cancelled',
        custom_attributes: appointment.custom_attributes.merge(marker_key => { 'reception_code' => 'reception-1' })
      )
      expect(appointment.custom_attributes).not_to have_key('medelement_local_cancelled_at')

      appointment.update!(status: 'scheduled')
      expect(appointment.reload.custom_attributes).not_to have_key(marker_key)
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

  describe 'confirmation after a move to another day' do
    let(:account) { create(:account) }
    let(:resource) { create(:scheduling_resource, account: account, timezone: 'Asia/Almaty') }
    let(:starts_at) { Time.utc(2026, 10, 27, 10, 30) } # 15:30 on 27.10 in Almaty
    let(:status) { 'confirmed' }
    let(:appointment) do
      create(:scheduling_appointment, account: account, resource: resource, status: status,
                                      starts_at: starts_at, ends_at: starts_at + 30.minutes)
    end

    def move_to(new_starts_at, **extra)
      appointment.update!(starts_at: new_starts_at, ends_at: new_starts_at + 30.minutes, **extra)
      appointment.reload
    end

    it 'sets a confirmed appointment back to scheduled when it moves to another day' do
      appointment.update_columns(attendance_confirmed_at: Time.current) # rubocop:disable Rails/SkipsModelValidations

      move_to(starts_at + 1.day)

      expect(appointment).to have_attributes(status: 'scheduled', attendance_confirmed_at: nil)
    end

    it 'keeps the confirmation when only the time changes within the same day' do
      move_to(starts_at + 2.hours)

      expect(appointment.status).to eq('confirmed')
    end

    it 'keeps the confirmation when other fields change without a new start' do
      appointment.update!(client_comment: 'Bring the analysis')

      expect(appointment.reload.status).to eq('confirmed')
    end

    it 'changes the status in the same save that moves the day, so the saved row and the dispatched change agree' do
      captured = []
      allow(Rails.configuration.dispatcher).to receive(:dispatch) { |name, _, data| captured << [name, data] }
      appointment

      move_to(starts_at + 3.days)

      changes = captured.reverse.find { |name, _| name == Events::Types::APPOINTMENT_UPDATED }.last[:changed_attributes]
      expect(changes).to include('starts_at', 'status' => %w[confirmed scheduled])
    end

    context 'when the day changes only in the timezone of the specialist' do
      let(:starts_at) { Time.utc(2026, 10, 27, 18, 30) } # 23:30 on 27.10 in Almaty

      it 'resets the confirmation although the UTC date stays the same' do
        move_to(Time.utc(2026, 10, 27, 19, 30)) # 00:30 on 28.10 in Almaty

        expect(appointment.status).to eq('scheduled')
      end
    end

    context 'when the UTC date changes but the day of the specialist does not' do
      let(:starts_at) { Time.utc(2026, 10, 27, 20, 30) } # 01:30 on 28.10 in Almaty

      it 'keeps the confirmation' do
        move_to(Time.utc(2026, 10, 28, 1, 0)) # 06:00 on 28.10 in Almaty

        expect(appointment.status).to eq('confirmed')
      end
    end

    context 'when the specialist works in another timezone' do
      let(:resource) { create(:scheduling_resource, account: account, timezone: 'America/New_York') }
      let(:starts_at) { Time.utc(2026, 10, 27, 14, 0) } # 10:00 on 27.10 in New York

      it 'compares the days in that timezone' do
        move_to(Time.utc(2026, 10, 28, 3, 0)) # 23:00 on 27.10 in New York

        expect(appointment.status).to eq('confirmed')

        move_to(Time.utc(2026, 10, 28, 5, 0)) # 01:00 on 28.10 in New York

        expect(appointment.status).to eq('scheduled')
      end
    end

    %w[cancelled completed no_show].each do |terminal_status|
      context "when the appointment is #{terminal_status}" do
        let(:status) { terminal_status }

        it 'is not touched by a move to another day' do
          move_to(starts_at + 1.day)

          expect(appointment.status).to eq(terminal_status)
        end
      end
    end

    context 'when the appointment is scheduled' do
      let(:status) { 'scheduled' }

      it 'stays scheduled' do
        move_to(starts_at + 1.day)

        expect(appointment.status).to eq('scheduled')
      end

      it 'is confirmed by the same save that moves it, as that is the staff confirming the new date' do
        move_to(starts_at + 1.day, status: 'confirmed')

        expect(appointment.status).to eq('confirmed')
      end
    end

    it 'does not touch a new appointment created as confirmed' do
      created = create(:scheduling_appointment, account: account, resource: resource, status: 'confirmed', starts_at: starts_at + 5.days)

      expect(created.reload.status).to eq('confirmed')
    end

    it 'asks again for a second move to another day after the new date was confirmed' do
      move_to(starts_at + 1.day)
      appointment.update!(status: 'confirmed')

      move_to(starts_at + 2.days)

      expect(appointment.status).to eq('scheduled')
    end
  end

  describe 'inside a MedElement reconciliation' do
    let(:appointment) { create(:scheduling_appointment) }
    let(:event_names) { [] }

    before do
      appointment
      allow(Rails.configuration.dispatcher.sync_dispatcher).to receive(:dispatch)
      allow(Rails.configuration.dispatcher.async_dispatcher).to receive(:dispatch) { |event_name, *| event_names << event_name }
    end

    it 'dispatches no appointment event, not even for a status change', :aggregate_failures do
      Current.with_medelement_reconciliation { appointment.update!(status: 'completed') }
      Current.with_medelement_reconciliation { appointment.update!(status: 'cancelled') }
      Current.with_medelement_reconciliation { appointment.update!(client_name: 'Corrected') }

      expect(event_names).to be_empty
      expect(appointment.reload).to have_attributes(status: 'cancelled', client_name: 'Corrected')
    end

    it 'does not leak into the next update, which dispatches as usual', :aggregate_failures do
      Current.with_medelement_reconciliation { appointment.update!(status: 'completed') }
      appointment.update!(client_name: 'Edited by staff')

      expect(Current.medelement_reconciliation).to be_nil
      expect(event_names).to eq([Events::Types::APPOINTMENT_UPDATED])
    end

    it 'puts the flag back when the block fails, and Current.reset clears it', :aggregate_failures do
      expect { Current.with_medelement_reconciliation { raise 'boom' } }.to raise_error('boom')
      expect(Current.medelement_reconciliation).to be_nil

      Current.with_medelement_reconciliation do
        expect(Current.medelement_reconciliation).to be(true)
        Current.reset
        expect(Current.medelement_reconciliation).to be_nil
      end
    end
  end
end
