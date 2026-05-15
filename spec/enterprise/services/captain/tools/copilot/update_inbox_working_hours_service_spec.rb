require 'rails_helper'

RSpec.describe Captain::Tools::Copilot::UpdateInboxWorkingHoursService do
  let(:account) { create(:account) }
  let(:user) { create(:user, :administrator, account: account) }
  let(:assistant) { create(:captain_assistant, account: account) }
  let(:service) { described_class.new(assistant, user: user) }

  before do
    confirmation_gate = instance_double(Captain::Copilot::ToolConfirmationGate, call: nil)
    allow(Captain::Copilot::ToolConfirmationGate).to receive(:new).and_return(confirmation_gate)
  end

  it 'updates inbox working hours and toggle inside the assistant account' do
    inbox = create(:inbox, account: account, working_hours_enabled: false)
    schedule = [
      {
        day_of_week: 1,
        open_hour: 10,
        open_minutes: 30,
        close_hour: 19,
        close_minutes: 0,
        open_all_day: false,
        closed_all_day: false
      },
      { day_of_week: 6, open_all_day: false, closed_all_day: true }
    ]

    payload = JSON.parse(service.execute(
                           inbox_id: inbox.id,
                           working_hours_json: schedule.to_json,
                           working_hours_enabled: true
                         ))

    expect(payload['action']).to eq('update_inbox_working_hours')
    expect(payload['inbox']).to include('id' => inbox.id, 'working_hours_enabled' => true)
    monday = inbox.working_hours.find_by(day_of_week: 1)
    saturday = inbox.working_hours.find_by(day_of_week: 6)
    expect(monday).to have_attributes(open_hour: 10, open_minutes: 30, close_hour: 19, close_minutes: 0)
    expect(saturday).to be_closed_all_day
  end

  it 'rejects invalid working hours JSON' do
    inbox = create(:inbox, account: account)

    result = service.execute(inbox_id: inbox.id, working_hours_json: '{bad')

    expect(result).to include('working_hours_json must be valid JSON')
  end

  it 'does not mutate until the backend confirmation gate permits execution' do
    allow(Captain::Copilot::ToolConfirmationGate).to receive(:new).and_call_original
    inbox = create(:inbox, account: account, working_hours_enabled: false)
    schedule = [{ day_of_week: 1, open_hour: 10, open_minutes: 0, close_hour: 18, close_minutes: 0 }]

    payload = JSON.parse(service.execute(inbox_id: inbox.id, working_hours_json: schedule.to_json, working_hours_enabled: true))

    expect(payload['message']).to include('Operator confirmation is required')
    expect(inbox.reload.working_hours_enabled).to be(false)
  end
end
