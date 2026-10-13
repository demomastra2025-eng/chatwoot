require 'rails_helper'

RSpec.describe Captain::Tools::Operations::AppointmentOperations, type: :model do
  include ActiveSupport::Testing::TimeHelpers

  around { |example| travel_to(Time.utc(2026, 4, 19, 12)) { example.run } }

  let(:account) { create(:account) }
  let(:assistant) { create(:captain_assistant, account: account) }
  let(:resource) { create(:scheduling_resource, account: account, timezone: 'Asia/Almaty', slot_duration_min: 30) }
  let(:contact) { create(:contact, account: account) }
  let(:conversation) { create(:conversation, account: account, contact: contact) }
  let(:booking) { { resource_id: resource.id, starts_at: '2026-04-20T09:00:00+05:00', duration_min: 30 } }

  before do
    account.enable_features!('scheduling')
    create(:scheduling_work_rule, resource: resource, weekday: 1, start_minute: 9 * 60, end_minute: 18 * 60)
    service = create(:scheduling_service, account: account, duration_min: 30)
    create(:scheduling_service_price, account: account, service: service, resource: resource, active: true, price: 20_000)
  end

  def operations_for(actor)
    described_class.new(assistant: assistant, conversation: conversation, actor: actor)
  end

  describe 'a booking of the agent' do
    let(:operations) { operations_for(assistant) }

    it 'takes the one service of the specialist when the call names none' do
      appointment = operations.create_appointment(**booking)

      expect(appointment.service_id).to eq(account.scheduling_services.first.id)
      expect(operations.already_booked_appointment).to be_nil
    end

    it 'reports the appointment it found instead of booking again, and forgets it on the next booking' do
      first = operations.create_appointment(**booking)

      expect(operations.create_appointment(**booking)).to eq(first)
      expect(operations.already_booked_appointment).to eq(first)

      later = operations.create_appointment(**booking, starts_at: '2026-04-20T10:00:00+05:00')

      expect(later).not_to eq(first)
      expect(operations.already_booked_appointment).to be_nil
    end
  end

  describe 'a booking of staff' do
    let(:user) { create(:user, account: account, role: :administrator) }
    let(:operations) { operations_for(user) }

    it 'leaves the service to the staff member: none is chosen for them' do
      appointment = operations.create_appointment(**booking)

      expect(appointment.service_id).to be_nil
    end

    it 'keeps the taken-slot error of a repeated booking: staff see the conflict, not an answer of the agent' do
      operations.create_appointment(**booking)

      expect { operations.create_appointment(**booking) }.to raise_error(Scheduling::Error) { |error|
        expect(Captain::Tools::Agent::AppointmentResult::CONFLICT_CODES).to include(error.code)
      }
      expect(operations.already_booked_appointment).to be_nil
    end
  end
end
