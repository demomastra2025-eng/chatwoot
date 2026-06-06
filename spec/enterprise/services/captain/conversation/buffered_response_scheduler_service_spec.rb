require 'rails_helper'

RSpec.describe Captain::Conversation::BufferedResponseSchedulerService do
  let(:account) { create(:account, custom_attributes: { plan_name: 'startups' }) }
  let(:inbox) { create(:inbox, account: account) }
  let(:assistant) do
    create(
      :captain_assistant,
      account: account,
      config: { 'message_collapse_window_seconds' => 3 }
    )
  end
  let(:conversation) { create(:conversation, inbox: inbox, account: account, status: :pending) }
  let(:configured_job) { instance_double(ActiveJob::ConfiguredJob) }
  let(:scheduled_waits) { [] }
  let(:scheduled_payloads) { [] }
  let(:state_key) { format(Redis::Alfred::CAPTAIN_MESSAGE_BUFFER_STATE, conversation_id: conversation.id) }

  before do
    allow(Captain::Conversation::ResponseBuilderJob).to receive(:set) do |wait:|
      scheduled_waits << wait
      configured_job
    end
    allow(configured_job).to receive(:perform_later) do |*args, **kwargs|
      scheduled_payloads << { args: args, kwargs: kwargs }
    end
  end

  after do
    Redis::Alfred.delete(state_key)
  end

  it 'overwrites the Redis buffer state when a newer incoming message arrives' do
    first_message = create(:message, conversation: conversation, content: 'First', message_type: :incoming)
    described_class.new(conversation: conversation, assistant: assistant, message: first_message).perform
    first_state = JSON.parse(Redis::Alfred.get(state_key))

    second_message = create(:message, conversation: conversation, content: 'Second', message_type: :incoming)
    described_class.new(conversation: conversation, assistant: assistant, message: second_message).perform
    second_state = JSON.parse(Redis::Alfred.get(state_key))

    expect(first_state['last_message_id']).to eq(first_message.id)
    expect(second_state['last_message_id']).to eq(second_message.id)
    expect(second_state['assistant_id']).to eq(assistant.id)
    expect(second_state['token']).not_to eq(first_state['token'])
    expect(scheduled_payloads.map { |payload| payload[:args] }).to eq([[conversation, assistant], [conversation, assistant]])
    expect(scheduled_payloads.map { |payload| payload.dig(:kwargs, :buffer_token) }).to eq([first_state['token'], second_state['token']])
    expect(scheduled_payloads.map { |payload| payload.dig(:kwargs, :expected_last_message_id) }).to eq([first_message.id, second_message.id])
  end

  it 'uses the longer wait when attachment processing needs more time than the collapse window' do
    message = create(:message, conversation: conversation, content: 'Image coming', message_type: :incoming)

    described_class.new(
      conversation: conversation,
      assistant: assistant,
      message: message,
      attachment_wait_time: 5.seconds
    ).perform

    expect(scheduled_waits.last).to eq(5.seconds)
  end

  it 'uses the collapse window when attachments do not need a longer wait' do
    message = create(:message, conversation: conversation, content: 'Plain text', message_type: :incoming)

    described_class.new(
      conversation: conversation,
      assistant: assistant,
      message: message,
      attachment_wait_time: 1.second
    ).perform

    expect(scheduled_waits.last).to eq(3.seconds)
  end
end
