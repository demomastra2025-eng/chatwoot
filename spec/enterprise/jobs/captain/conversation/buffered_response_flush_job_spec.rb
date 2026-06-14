require 'rails_helper'

RSpec.describe Captain::Conversation::BufferedResponseFlushJob, type: :job do
  let(:account) { create(:account, custom_attributes: { plan_name: 'startups' }) }
  let(:inbox) { create(:inbox, account: account) }
  let(:assistant) { create(:captain_assistant, account: account) }
  let(:conversation) { create(:conversation, inbox: inbox, account: account, status: :pending) }
  let(:state_key) { format(Redis::Alfred::CAPTAIN_MESSAGE_BUFFER_STATE, conversation_id: conversation.id) }
  let(:lock_key) { format(Redis::Alfred::CAPTAIN_MESSAGE_BUFFER_LOCK, conversation_id: conversation.id) }

  before do
    create(:captain_inbox, inbox: inbox, captain_assistant: assistant)
  end

  after do
    Redis::Alfred.delete(state_key)
    Redis::Alfred.delete(lock_key)
  end

  it 'does not call ResponseBuilderJob for a stale token and keeps the latest state intact' do
    latest_message = create(:message, conversation: conversation, content: 'Latest', message_type: :incoming)
    latest_token = SecureRandom.uuid
    Redis::Alfred.set(
      state_key,
      {
        token: latest_token,
        assistant_id: assistant.id,
        last_message_id: latest_message.id
      }.to_json,
      ex: 10.minutes.to_i
    )

    expect(Captain::Conversation::ResponseBuilderJob).not_to receive(:perform_now)

    described_class.perform_now(conversation_id: conversation.id, assistant_id: assistant.id, token: 'stale-token')

    expect(JSON.parse(Redis::Alfred.get(state_key))['token']).to eq(latest_token)
  end

  it 'calls ResponseBuilderJob only for the current token and latest incoming message id' do
    latest_message = create(:message, conversation: conversation, content: 'Latest', message_type: :incoming)
    latest_token = SecureRandom.uuid
    Redis::Alfred.set(
      state_key,
      {
        token: latest_token,
        assistant_id: assistant.id,
        last_message_id: latest_message.id
      }.to_json,
      ex: 10.minutes.to_i
    )

    expect(Captain::Conversation::ResponseBuilderJob).to receive(:perform_now).with(
      conversation,
      assistant,
      buffer_token: latest_token,
      expected_last_message_id: latest_message.id
    )

    described_class.perform_now(conversation_id: conversation.id, assistant_id: assistant.id, token: latest_token)
  end

  it 'clears the current buffer state without answering when the conversation is open and open replies are disabled' do
    latest_message = create(:message, conversation: conversation, content: 'Latest', message_type: :incoming)
    latest_token = SecureRandom.uuid
    conversation.open!
    Redis::Alfred.set(
      state_key,
      {
        token: latest_token,
        assistant_id: assistant.id,
        last_message_id: latest_message.id
      }.to_json,
      ex: 10.minutes.to_i
    )

    expect(Captain::Conversation::ResponseBuilderJob).not_to receive(:perform_now)

    described_class.perform_now(conversation_id: conversation.id, assistant_id: assistant.id, token: latest_token)

    expect(Redis::Alfred.get(state_key)).to be_nil
  end

  it 'calls ResponseBuilderJob for open conversations when open replies are enabled' do
    latest_message = create(:message, conversation: conversation, content: 'Latest', message_type: :incoming)
    latest_token = SecureRandom.uuid
    inbox.captain_inbox.update!(reply_to_open_conversations: true)
    conversation.open!
    Redis::Alfred.set(
      state_key,
      {
        token: latest_token,
        assistant_id: assistant.id,
        last_message_id: latest_message.id
      }.to_json,
      ex: 10.minutes.to_i
    )

    expect(Captain::Conversation::ResponseBuilderJob).to receive(:perform_now).with(
      conversation,
      assistant,
      buffer_token: latest_token,
      expected_last_message_id: latest_message.id
    )

    described_class.perform_now(conversation_id: conversation.id, assistant_id: assistant.id, token: latest_token)
  end

  it 'clears the current buffer state without answering when captain auto-reply is no longer allowed' do
    latest_message = create(:message, conversation: conversation, content: 'Latest', message_type: :incoming)
    latest_token = SecureRandom.uuid
    inbox.update!(working_hours_enabled: true)
    inbox.working_hours.find_by(day_of_week: Time.current.in_time_zone(inbox.timezone).wday).update!(
      closed_all_day: true,
      open_all_day: false
    )
    inbox.captain_inbox.update!(auto_reply_mode: 'working_hours')
    Redis::Alfred.set(
      state_key,
      {
        token: latest_token,
        assistant_id: assistant.id,
        last_message_id: latest_message.id
      }.to_json,
      ex: 10.minutes.to_i
    )

    expect(Captain::Conversation::ResponseBuilderJob).not_to receive(:perform_now)

    described_class.perform_now(conversation_id: conversation.id, assistant_id: assistant.id, token: latest_token)

    expect(Redis::Alfred.get(state_key)).to be_nil
  end
end
