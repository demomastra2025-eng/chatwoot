require 'rails_helper'

RSpec.describe 'Touch Plans API', type: :request do
  let(:account) { create(:account) }
  let(:administrator) { create(:user, account: account, role: :administrator) }
  let(:headers) { administrator.create_new_auth_token }
  let(:appointment) { create(:scheduling_appointment, account: account) }
  let(:path) { "/api/v1/accounts/#{account.id}/touch_plans" }

  it 'lists touch plans' do
    create(:reminder_group, account: account, name: 'Appointments')

    get path, headers: headers, as: :json

    expect(response).to have_http_status(:ok)
    expect(response.parsed_body.dig('meta', 'count')).to eq(1)
    expect(response.parsed_body.dig('payload', 0, 'name')).to eq('Appointments')
  end

  it 'creates a touch plan' do
    post path,
         params: {
           name: 'New patient sequence',
           entity_kinds: ['appointment'],
           touches: [
             {
               action_type: 'send_message',
               content_kind: 'free_text',
               timing_mode: 'relative',
               relative_anchor: 'appointment.starts_at',
               relative_offset_seconds: -3600,
               timezone: 'UTC',
               body: 'Appointment for {{contact.name}} in one hour'
             }
           ]
         },
         headers: headers,
         as: :json

    expect(response).to have_http_status(:created)
    expect(response.parsed_body.dig('payload', 'name')).to eq('New patient sequence')
    expect(response.parsed_body.dig('payload', 'touches', 0, 'text_mode')).to eq('dynamic')
    expect(account.reminder_groups.count).to eq(1)
  end

  it 'applies a touch plan to an appointment' do
    touch_plan = create(:reminder_group, account: account, entity_kinds: ['appointment'])

    post "#{path}/#{touch_plan.id}/apply",
         params: {
           remindable_type: 'Scheduling::Appointment',
           remindable_id: appointment.id
         },
         headers: headers,
         as: :json

    expect(response).to have_http_status(:created)
    expect(response.parsed_body.dig('meta', 'count')).to eq(1)
    expect(account.reminders.where(reminder_group: touch_plan).count).to eq(1)
  end

  it 'archives a touch plan' do
    touch_plan = create(:reminder_group, account: account)

    post "#{path}/#{touch_plan.id}/archive", headers: headers, as: :json

    expect(response).to have_http_status(:ok)
    expect(response.parsed_body.dig('payload', 'active')).to be(false)
    expect(touch_plan.reload.archived_at).to be_present
  end
end
