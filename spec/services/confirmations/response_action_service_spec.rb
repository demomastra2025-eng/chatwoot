require 'rails_helper'

RSpec.describe Confirmations::ResponseActionService do
  it 'confirms a scheduled read-only MedElement appointment locally' do
    account = create(:account)
    appointment = create(
      :scheduling_appointment,
      account: account,
      source: 'medelement',
      external_ref: 'medelement:reception:confirmation-test',
      status: 'scheduled'
    )
    reminder = instance_double(
      Reminder,
      response_action: 'confirm_appointment',
      remindable: appointment,
      metadata: {}
    )
    confirmation_request = instance_double(
      ConfirmationRequest,
      account: account,
      account_id: account.id,
      reminder: reminder,
      subject: appointment
    )

    outcome = described_class.new(confirmation_request: confirmation_request, decision: 'confirmed').perform

    expect(outcome).to eq('appointment_confirmed')
    expect(appointment.reload.status).to eq('confirmed')
  end

  it 'records a declined response without cancelling a read-only provider appointment' do
    account = create(:account)
    appointment = create(
      :scheduling_appointment,
      account: account,
      source: 'medelement',
      external_ref: 'medelement:reception:decline-test',
      status: 'scheduled'
    )
    reminder = instance_double(
      Reminder,
      response_action: 'confirm_appointment',
      remindable: appointment,
      metadata: {}
    )
    confirmation_request = instance_double(
      ConfirmationRequest,
      account: account,
      account_id: account.id,
      reminder: reminder,
      subject: appointment
    )

    outcome = described_class.new(confirmation_request: confirmation_request, decision: 'declined').perform

    expect(outcome).to eq('decision_recorded')
    expect(appointment.reload.status).to eq('scheduled')
  end
end
