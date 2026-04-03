require 'rails_helper'

RSpec.describe Scheduling::Appointment do
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

    it 'dispatches appointment.cancelled when status changes to cancelled' do
      captured_events = []
      allow(Rails.configuration.dispatcher).to receive(:dispatch) do |event_name, _, data|
        captured_events << [event_name, data]
      end

      appointment.update!(status: 'cancelled')

      expect(captured_events.map(&:first)).to include(Events::Types::APPOINTMENT_UPDATED, Events::Types::APPOINTMENT_CANCELLED)
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
