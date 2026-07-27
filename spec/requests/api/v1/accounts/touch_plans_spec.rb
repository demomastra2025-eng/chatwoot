require 'rails_helper'

RSpec.describe 'Touch Plans API', type: :request do
  let(:account) { create(:account) }
  let(:administrator) { create(:user, account: account, role: :administrator) }
  let(:headers) { administrator.create_new_auth_token }
  let(:appointment) { create(:scheduling_appointment, account: account) }
  let(:assistant) { create(:captain_assistant, account: account) }
  let(:path) { "/api/v1/accounts/#{account.id}/touch_plans" }

  it 'lists touch plans' do
    create(:reminder_group, account: account, name: 'Appointments')

    get path, headers: headers, as: :json

    expect(response).to have_http_status(:ok)
    expect(response.parsed_body.dig('meta', 'count')).to eq(1)
    expect(response.parsed_body.dig('payload', 0, 'name')).to eq('Appointments')
  end

  it 'lists shared and assistant-owned touch plans for an assistant workspace' do
    shared_plan = create(:reminder_group, account: account, name: 'Shared plan')
    assistant_plan = create(:reminder_group, account: account, assistant: assistant, name: 'Assistant plan')
    other_assistant = create(:captain_assistant, account: account)
    create(:reminder_group, account: account, assistant: other_assistant, name: 'Other assistant plan')

    get path, params: { assistant_id: assistant.id }, headers: headers, as: :json

    expect(response).to have_http_status(:ok)
    expect(response.parsed_body.dig('meta', 'count')).to eq(2)
    expect(response.parsed_body['payload'].pluck('id')).to contain_exactly(shared_plan.id, assistant_plan.id)
  end

  it 'creates a touch plan' do
    post path,
         params: {
           name: 'New patient sequence',
           entity_kinds: ['appointment'],
           touches: [
             {
               entity_kind: 'appointment',
               action_type: 'send_message',
               content_kind: 'free_text',
               timing_mode: 'relative',
               relative_anchor: 'appointment.starts_at',
               relative_offset_seconds: -3600,
               relative_time_mode: 'fixed_time_of_day',
               relative_time_of_day: '10:00',
               timezone: 'UTC',
               body: 'Appointment for {{contact.name}} in one hour'
             }
           ]
         },
         headers: headers,
         as: :json

    expect(response).to have_http_status(:created)
    expect(response.parsed_body.dig('payload', 'name')).to eq('New patient sequence')
    expect(response.parsed_body.dig('payload', 'touches', 0, 'entity_kind')).to eq('appointment')
    expect(response.parsed_body.dig('payload', 'touches', 0, 'text_mode')).to eq('dynamic')
    expect(
      response.parsed_body.dig('payload', 'touches', 0, 'relative_time_mode')
    ).to eq('fixed_time_of_day')
    expect(
      response.parsed_body.dig('payload', 'touches', 0, 'relative_time_of_day')
    ).to eq('10:00')
    expect(account.reminder_groups.count).to eq(1)
  end

  it 'round-trips a conversation post-delivery action in a touch plan' do
    post path,
         params: {
           name: 'Final conversation follow-up',
           entity_kinds: ['conversation'],
           touches: [
             {
               content_kind: 'free_text',
               timing_mode: 'absolute',
               repeat_mode: 'once',
               scheduled_at: 1.hour.from_now.iso8601,
               timezone: 'UTC',
               body: 'Final follow-up',
               post_delivery_action: 'resolve_conversation'
             }
           ]
         },
         headers: headers,
         as: :json

    expect(response).to have_http_status(:created)
    expect(response.parsed_body.dig('payload', 'touches', 0, 'post_delivery_action')).to eq('resolve_conversation')
    expect(account.reminder_groups.sole.touches.first['post_delivery_action']).to eq('resolve_conversation')
  end

  it 'rejects post-delivery actions on non-conversation touch plans' do
    post path,
         params: {
           name: 'Invalid appointment follow-up',
           entity_kinds: ['appointment'],
           touches: [
             {
               action_type: 'send_message',
               repeat_mode: 'once',
               body: 'Should not resolve a related conversation',
               post_delivery_action: 'resolve_conversation'
             }
           ]
         },
         headers: headers,
         as: :json

    expect(response).to have_http_status(:unprocessable_content)
    expect(account.reminder_groups).to be_empty
  end

  it 'rejects a declared entity kind without a matching or shared step' do
    post path,
         params: {
           name: 'Incomplete mixed plan',
           entity_kinds: %w[appointment deal],
           touches: [
             {
               entity_kind: 'appointment',
               body: 'Appointment-only follow-up'
             }
           ]
         },
         headers: headers,
         as: :json

    expect(response).to have_http_status(:unprocessable_content)
    expect(account.reminder_groups).to be_empty
  end

  it 'creates an assistant-scoped touch plan' do
    post path,
         params: {
           assistant_id: assistant.id,
           name: 'AI follow-up scenario',
           entity_kinds: ['conversation'],
           touches: [
             {
               action_type: 'send_message',
               content_kind: 'free_text',
               timing_mode: 'relative',
               relative_anchor: 'conversation.last_incoming_message_at',
               relative_offset_seconds: 3600,
               timezone: 'UTC',
               body: 'I will follow up in one hour'
             }
           ]
         },
         headers: headers,
         as: :json

    expect(response).to have_http_status(:created)
    expect(response.parsed_body.dig('payload', 'assistant_id')).to eq(assistant.id)
    expect(response.parsed_body.dig('payload', 'assistant', 'name')).to eq(assistant.name)
    expect(account.reminder_groups.sole.assistant).to eq(assistant)
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

  it 'enrolls an eligible appointment plan without future reminders when deferred mode is enabled' do
    account.enable_features!('deferred_touch_materialization')
    touch_plan = create(:reminder_group, account: account, entity_kinds: ['appointment'])

    post "#{path}/#{touch_plan.id}/apply",
         params: {
           remindable_type: 'Scheduling::Appointment',
           remindable_id: appointment.id
         },
         headers: headers,
         as: :json

    expect(response).to have_http_status(:created)
    expect(response.parsed_body['payload']).to eq([])
    expect(response.parsed_body['meta']).to include('count' => 0, 'execution_mode' => 'deferred')
    expect(response.parsed_body.dig('meta', 'enrollment_id')).to eq(account.touch_plan_enrollments.sole.id)
    expect(account.reminders.where(reminder_group: touch_plan)).to be_empty
  end

  it 'applies a conversation touch plan using the conversation display identifier' do
    conversation = create(:conversation, account: account)
    conversation.update!(display_id: 88)
    touch_plan = create(
      :reminder_group,
      account: account,
      entity_kinds: ['conversation'],
      touches: [
        {
          action_type: 'send_message',
          content_kind: 'free_text',
          timing_mode: 'absolute',
          scheduled_at: 1.hour.from_now.iso8601,
          timezone: 'UTC',
          body: 'Conversation follow-up'
        }
      ]
    )

    post "#{path}/#{touch_plan.id}/apply",
         params: {
           remindable_type: 'Conversation',
           remindable_id: conversation.display_id
         },
         headers: headers,
         as: :json

    expect(response).to have_http_status(:created)
    touch = account.reminders.where(reminder_group: touch_plan).sole
    expect(touch).to have_attributes(
      remindable: conversation,
      conversation: conversation
    )
  end

  it 'archives a touch plan' do
    touch_plan = create(:reminder_group, account: account)

    post "#{path}/#{touch_plan.id}/archive", headers: headers, as: :json

    expect(response).to have_http_status(:ok)
    expect(response.parsed_body.dig('payload', 'active')).to be(false)
    expect(touch_plan.reload.archived_at).to be_present
  end
end
