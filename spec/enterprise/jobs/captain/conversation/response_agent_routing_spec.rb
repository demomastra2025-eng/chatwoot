# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Captain::Conversation::ResponseBuilderJob, type: :job do
  let(:account) { create(:account, custom_attributes: { plan_name: 'startups' }) }
  let(:inbox) { create(:inbox, account: account) }
  let(:conversation) { create(:conversation, account: account, inbox: inbox, status: :pending) }
  let(:entry) { create(:captain_assistant, account: account, config: follow_up_config('Entry follow-up')) }
  let(:actor) { create(:captain_assistant, account: account, config: follow_up_config('Specialist follow-up')) }
  let(:runner) { instance_double(Captain::Assistant::AgentRunnerService) }

  before do
    account.enable_features!('captain_integration', 'captain_tasks')
    create(:captain_inbox, inbox: inbox, captain_assistant: entry)
    entry.update!(handoff_agent_ids: [actor.id])
    create(:message, conversation: conversation, message_type: :incoming, content: 'Help with my booking')
    allow(Captain::Assistant::AgentRunnerService).to receive(:new).and_return(runner)
    allow(Captain::Conversation::TypingIndicatorService).to receive(:turn_on)
    allow(Captain::Conversation::TypingIndicatorService).to receive(:turn_off)
  end

  def follow_up_config(content)
    { 'follow_up_settings' => { 'enabled' => true, 'prompt' => '',
                               'steps' => [{ 'mode' => 'static', 'message' => content, 'delay_seconds' => 60 }] } }
  end

  def route_to(assistant)
    Captain::Conversation::AgentSession.new(entry: entry, conversation: conversation).update_routing(actor_id: assistant.id)
  end

  def response_from(assistant, attributes = {})
    allow(runner).to receive(:generate_response) do
      route_to(assistant)
      { 'response' => 'Your booking is ready.', 'agent_id' => assistant.id, 'agent_name' => "assistant_#{assistant.id}" }.merge(attributes)
    end
  end

  it 'keeps the input buffer on the entry agent and sends the specialist reply with its own follow-up settings' do
    incoming = conversation.messages.incoming.last
    buffer_key = format(Redis::Alfred::CAPTAIN_MESSAGE_BUFFER_STATE, conversation_id: conversation.id)
    Redis::Alfred.set(buffer_key, { token: 'entry-buffer', assistant_id: entry.id, last_message_id: incoming.id,
                                  control_generation: conversation.current_captain_control_generation }.to_json, ex: 60)
    response_from(actor)

    described_class.perform_now(conversation, entry, buffer_token: 'entry-buffer', expected_last_message_id: incoming.id)

    reply = conversation.messages.outgoing.where(private: false).last
    expect(reply.sender).to eq(actor)
    expect(reply.additional_attributes).to include('agent_name' => "assistant_#{actor.id}", 'agentName' => actor.name,
                                                 'captain_ai_reply' => { 'assistant_id' => actor.id })
    expect(Captain::Assistant::AgentRunnerService).to have_received(:new).with(hash_including(assistant: entry))
    reminder = account.reminders.captain_follow_up.last
    expect(reminder).to be_present
    expect(reminder.metadata['captain_follow_up']).to include(
      'assistant_id' => actor.id, 'entry_assistant_id' => entry.id, 'routing_revision' => 1
    )
    expect(Redis::Alfred.get(buffer_key)).to be_nil
  ensure
    Redis::Alfred.delete(buffer_key) if defined?(buffer_key)
  end

  it 'uses the final specialist handoff settings and sender' do
    entry.update!(config: entry.config.merge('handoff_enabled' => false, 'handoff_message' => 'Entry notice'))
    actor.update!(config: actor.config.merge('handoff_enabled' => true, 'handoff_message_enabled' => true,
                                            'handoff_message_mode' => 'static', 'handoff_message' => 'Specialist notice'))
    response_from(actor, 'response' => 'conversation_handoff', 'handoff_tool_called' => true, 'handoff_authorized' => true)

    described_class.perform_now(conversation, entry)

    expect(conversation.reload).to be_open
    notice = conversation.messages.outgoing.where(private: false).last
    expect(notice.content).to eq('Specialist notice')
    expect(notice.sender).to eq(actor)
    expect(account.reminders.captain_follow_up).to be_empty
  end

  it 'drops a reachable actor result that no longer owns the conversation' do
    allow(runner).to receive(:generate_response).and_return('response' => 'Stale specialist reply', 'agent_id' => actor.id)

    described_class.perform_now(conversation, entry)

    expect(conversation.messages.outgoing).to be_empty
    expect(account.reminders.captain_follow_up).to be_empty
  end

  it 'rejects an assistant outside the entry graph even if its ID appears in the result' do
    outsider = create(:captain_assistant, account: account)
    allow(runner).to receive(:generate_response).and_return('response' => 'Unreachable reply', 'agent_id' => outsider.id)

    described_class.perform_now(conversation, entry)

    expect(conversation.messages.outgoing).to be_empty
  end

  it 'preserves an existing internal entry conversation without enabling external follow-up' do
    entry.update_column(:usage_mode, 'internal_assistant') # rubocop:disable Rails/SkipsModelValidations
    allow(runner).to receive(:generate_response).and_return('response' => 'Internal response', 'agent_id' => entry.id)

    described_class.perform_now(conversation, entry.reload)

    expect(conversation.messages.outgoing.where(private: false).last.sender).to eq(entry)
    expect(account.reminders.captain_follow_up).to be_empty
  end
end
