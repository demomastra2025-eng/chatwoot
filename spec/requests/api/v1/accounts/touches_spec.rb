require 'rails_helper'

RSpec.describe 'Touches API', type: :request do
  let(:account) { create(:account) }
  let(:administrator) { create(:user, account: account, role: :administrator) }
  let(:headers) { administrator.create_new_auth_token }
  let(:conversation) { create(:conversation, account: account) }
  let(:path) { "/api/v1/accounts/#{account.id}/touches" }

  it 'lists touches for the account' do
    create(:reminder, account: account, touch_conversation: conversation, body: 'First touch')
    create(:reminder, account: account, touch_conversation: conversation, body: 'Second touch')

    get path, headers: headers, as: :json

    expect(response).to have_http_status(:ok)
    expect(response.parsed_body.dig('meta', 'count')).to eq(2)
    expect(response.parsed_body.dig('payload', 0, 'action_type')).to eq('send_message')
  end

  it 'creates a touch' do
    post path,
         params: {
           remindable_type: 'Conversation',
           remindable_id: conversation.id,
           conversation_id: conversation.id,
           target_inbox_id: conversation.inbox_id,
           target_contact_id: conversation.contact_id,
           target_contact_inbox_id: conversation.contact_inbox_id,
           scheduled_at: 1.hour.from_now.iso8601,
           repeat_mode: 'weekly',
           repeat_until_at: 1.month.from_now.iso8601,
           timezone: 'UTC',
           body: 'Follow up {{contact.name}} tomorrow'
         },
         headers: headers,
         as: :json

    expect(response).to have_http_status(:created)
    expect(response.parsed_body.dig('payload', 'status')).to eq('pending')
    expect(response.parsed_body.dig('payload', 'repeat_mode')).to eq('weekly')
    expect(response.parsed_body.dig('payload', 'text_mode')).to eq('dynamic')
    expect(account.reminders.count).to eq(1)
  end

  it 'rejects touches for records outside the current account' do
    foreign_conversation = create(:conversation)

    post path,
         params: {
           remindable_type: 'Conversation',
           remindable_id: foreign_conversation.id,
           scheduled_at: 1.hour.from_now.iso8601,
           timezone: 'UTC',
           body: 'This should not be created'
         },
         headers: headers,
         as: :json

    expect(response).to have_http_status(:not_found)
    expect(account.reminders.count).to eq(0)
  end

  it 'approves a draft touch' do
    touch = create(
      :reminder,
      :draft,
      account: account,
      touch_conversation: conversation,
      scheduled_at: 1.hour.from_now
    )

    post "#{path}/#{touch.id}/approve", headers: headers, as: :json

    expect(response).to have_http_status(:ok)
    expect(response.parsed_body.dig('payload', 'status')).to eq('pending')
    expect(touch.reload).to be_pending
  end

  it 'cancels a touch' do
    touch = create(:reminder, account: account, touch_conversation: conversation)

    post "#{path}/#{touch.id}/cancel", params: { reason: 'No longer needed' }, headers: headers, as: :json

    expect(response).to have_http_status(:ok)
    expect(response.parsed_body.dig('payload', 'status')).to eq('cancelled')
    expect(touch.reload.last_error).to eq('No longer needed')
  end

  it 'deletes a pending delayed message' do
    touch = create(:reminder, account: account, touch_conversation: conversation)

    delete "#{path}/#{touch.id}", headers: headers, as: :json

    expect(response).to have_http_status(:ok)
    expect(account.reminders.exists?(touch.id)).to be(false)
  end

  it 'rejects deleting a completed delayed message' do
    touch = create(
      :reminder,
      account: account,
      touch_conversation: conversation,
      status: :completed,
      completed_at: Time.current
    )

    delete "#{path}/#{touch.id}", headers: headers, as: :json

    expect(response).to have_http_status(:unprocessable_entity)
    expect(response.parsed_body['error']).to eq('Only unsent delayed messages can be deleted.')
    expect(account.reminders.exists?(touch.id)).to be(true)
  end

  it 'allows custom-role users with outbound_view to list touches' do
    create(:reminder, account: account, touch_conversation: conversation)
    custom_role = create(:custom_role, account: account, permissions: ['outbound_view'])
    custom_role_user = create(:user, account: account, role: :agent)
    custom_role_user.account_users.find_by(account: account).update!(custom_role: custom_role)

    get path, headers: custom_role_user.create_new_auth_token, as: :json

    expect(response).to have_http_status(:ok)
    expect(response.parsed_body.dig('meta', 'count')).to eq(1)
  end
end
