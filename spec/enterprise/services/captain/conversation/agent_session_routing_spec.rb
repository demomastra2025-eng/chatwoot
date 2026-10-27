# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Captain::Conversation::AgentSession do
  let(:account) { create(:account) }
  let(:former_default) { create(:captain_assistant, account: account) }
  let(:specialist) { create(:captain_assistant, account: account) }
  let(:conversation) { create(:conversation, account: account) }
  let(:session) { described_class.new(conversation: conversation) }

  it 'starts a new conversation without an agent: the router chooses on the first message' do
    expect(session.read).to include('current_assistant_id' => nil, 'routing_revision' => 0, 'routing_trail' => [])
    expect(session.read).not_to have_key('tasks')
  end

  it 'reads a session stored with the former entry agent, with its current agent and parts, and does not wipe it' do
    stored = { 'entry_assistant_id' => former_default.id, 'current_assistant_id' => specialist.id, 'routing_revision' => 3, 'task_revision' => 3,
               'tasks' => [], 'parts' => [{ 'id' => 'p1', 'state' => 'done' }], 'done' => [{ 'tool' => 'create_appointment' }], 'operations' => {} }
    conversation.update!(additional_attributes: { described_class::ATTRIBUTE => stored })

    expect(described_class.new(conversation: conversation).read)
      .to include('current_assistant_id' => specialist.id, 'routing_revision' => 3, 'parts' => [{ 'id' => 'p1', 'state' => 'done' }],
                  'done' => [{ 'tool' => 'create_appointment' }])
  end

  it 'keeps the session of the conversation when the agent that was once the default is switched off' do
    stored = { 'entry_assistant_id' => former_default.id, 'current_assistant_id' => specialist.id, 'routing_revision' => 3, 'task_revision' => 3,
               'tasks' => [], 'parts' => [{ 'id' => 'p1', 'state' => 'done' }], 'operations' => {} }
    conversation.update!(additional_attributes: { described_class::ATTRIBUTE => stored })

    former_default.update!(active: false)

    expect(described_class.new(conversation: conversation).read)
      .to include('current_assistant_id' => specialist.id, 'parts' => [{ 'id' => 'p1', 'state' => 'done' }])
  end

  it 'raises the routing revision only when the holder changes and keeps the last three decisions' do
    session.update_routing(actor_id: specialist.id, trail: { 'kind' => 'agent', 'to' => [specialist.id] })
    session.update_routing(actor_id: specialist.id, trail: { 'kind' => 'agent', 'from' => specialist.id, 'to' => [specialist.id] })
    session.update_routing(actor_id: nil, trail: { 'kind' => 'human', 'from' => specialist.id, 'to' => [] })
    session.update_routing(actor_id: former_default.id, trail: { 'kind' => 'agent', 'from' => specialist.id, 'to' => [former_default.id] })

    saved = session.read
    expect(saved['current_assistant_id']).to eq(former_default.id)
    expect(saved['routing_revision']).to eq(2)
    expect(saved['routing_trail'].pluck('kind')).to eq(%w[agent human agent])
  end
end
