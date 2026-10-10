require 'rails_helper'

RSpec.describe Scheduling::Appointments::UpsertService do
  include ActiveSupport::Testing::TimeHelpers

  around { |example| travel_to(Time.utc(2026, 4, 20, 7)) { example.run } }

  let(:account) { create(:account) }
  let(:staff) { create(:user, account: account) }
  let(:resource) { create(:scheduling_resource, account: account, compensation_type: 'fixed', compensation_value: 0) }
  let(:appointment) do
    create(:scheduling_appointment, account: account, resource: resource, created_by: staff, service_amount: 0)
  end

  def complete(actor)
    described_class.new(account: account, appointment: appointment, actor: actor, params: { status: 'completed' }).perform
  end

  it 'records staff attendance only for a member of the appointment account' do
    result = complete(staff)

    expect(result).to have_attributes(status: 'completed', attendance_confirmed_at: Time.current)
  end

  it 'records attendance for the assistant belonging to the same account' do
    assistant = create(:captain_assistant, account: account)

    result = complete(assistant)

    expect(result).to have_attributes(status: 'completed', attendance_confirmed_at: Time.current)
  end

  it 'does not create attendance proof for a user from another account' do
    foreign_user = create(:user)

    result = complete(foreign_user)

    expect(result).to have_attributes(status: 'completed', attendance_confirmed_at: nil)
    expect(result.created_by_id).to eq(staff.id)
  end

  it 'does not create attendance proof for an assistant from another account' do
    foreign_assistant = create(:captain_assistant)

    result = complete(foreign_assistant)

    expect(result).to have_attributes(status: 'completed', attendance_confirmed_at: nil)
  end

  it 'keeps a background completed status separate from an actor confirming attendance' do
    result = complete(nil)

    expect(result).to have_attributes(status: 'completed', attendance_confirmed_at: nil)
  end

  it 'preserves an earlier attendance proof rather than renewing it through an unrelated account actor' do
    earlier_confirmation = 1.hour.ago
    appointment.update!(attendance_confirmed_at: earlier_confirmation)

    result = complete(create(:captain_assistant))

    expect(result.attendance_confirmed_at).to eq(earlier_confirmation)
  end
end
