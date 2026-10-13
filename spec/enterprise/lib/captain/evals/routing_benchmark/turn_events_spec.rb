# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Captain::Evals::RoutingBenchmark::TurnEvents do
  let(:account) { create(:account) }
  let(:event_class) { Struct.new(:event_name, :tool_name, :payload, :assistant_id, :status, :reason) }
  let(:names) { { 1 => 'Администратор', 2 => 'Запись к врачу' } }

  def event(name, payload = {}, tool: nil, status: nil, reason: nil) = event_class.new(name, tool, payload, nil, status, reason)

  def turn_events(*events) = described_class.new(events, agent_names: names)

  it 'lists the transfers with the names of the agents, and an agent it does not know by its key' do
    list = turn_events(event('captain.agent.transfer', { 'from_agent_id' => 1, 'to_agent_id' => 2 }),
                       event('captain.agent.transfer', { 'from_agent_id' => 2, 'to_agent_id' => 9 }))

    expect(list.transfers).to eq([{ from: 'Администратор', to: 'Запись к врачу' }, { from: 'Запись к врачу', to: 'assistant_9' }])
  end

  it 'lists the guards that stopped a transfer, with their reason (a column of the stored event)' do
    guard = event('captain.agent.transfer_guard', { 'from_agent_id' => 1 }, reason: 'target_not_allowed')

    expect(turn_events(guard).transfer_guards).to eq([{ reason: 'target_not_allowed', from: 'Администратор' }])
  end

  it 'has no council for a turn without a council event, and knows a council that started without a part' do
    expect(turn_events(event('llm.chat.request')).council).to be_nil
    expect(turn_events(event('captain.council.started', { 'participants' => [1, 2] })).council)
      .to eq(started: 1, participants: ['Администратор', 'Запись к врачу'], parts: [])
    expect(turn_events(event('captain.council.started')).part_started?).to be(false)
  end

  it 'merges the start and the end of a part by its id and version, and shows a part that did not finish' do
    list = turn_events(
      event('captain.council.part_started', { 'part_id' => 'abcdefghij', 'part_version' => 1, 'executor_agent_id' => 2, 'lane' => 'write', 'inline' => false }),
      event('captain.council.part_finished', { 'part_id' => 'abcdefghij', 'part_version' => 1, 'executor_agent_id' => 2, 'state' => 'done', 'acted' => true,
                                               'mutations_succeeded' => 1, 'mutations_failed' => 0, 'mutations_unknown' => 0, 'tools_called' => 3, 'turns' => 2 },
            status: 'answered'),
      event('captain.council.part_started', { 'part_id' => 'klmnopqrst', 'part_version' => 2, 'executor_agent_id' => 1, 'lane' => 'read' })
    )

    expect(list.council[:parts]).to eq([
                                         { part: 'abcdefgh', version: 1, owner: 'Запись к врачу', lane: 'write', inline: false, state: 'done', status: 'answered', acted: true,
                                           mutations_succeeded: 1, mutations_failed: 0, mutations_unknown: 0, tools_called: 3, turns: 2 },
                                         { part: 'klmnopqr', version: 2, owner: 'Администратор', lane: 'read', state: 'unfinished' }
                                       ])
    expect(list).to be_part_started
  end

  it 'reads the editor, its fallback and the outcome of the council' do
    list = turn_events(event('captain.council.started'), event('captain.council.edited', { 'language' => 'ru', 'handoff' => false }),
                       event('captain.council.editor_fallback', {}, reason: 'invalid'), event('captain.council.finished', { 'outcome' => 'answered' }))

    expect(list.council).to include(edited: { language: 'ru', handoff: false }, editor_fallback: 'invalid', outcome: 'answered')
    expect(list.editor_fallback).to eq('invalid')
  end

  it 'lists the tool failures that stopped a run, with names and codes only' do
    failure = event('captain.tool.technical_failure', { 'stage' => 'execution', 'mutating' => true }, tool: 'create_appointment', reason: 'provider_timeout')

    expect(turn_events(failure).technical_failures).to eq([{ tool: 'create_appointment', stage: 'execution', reason: 'provider_timeout', mutating: true }])
  end
end
