# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Llm::Evals::Scenario::JudgeAgent do
  it 'fails deterministically when expected scenario checks fail' do
    state = Llm::Evals::Scenario::State.new
    state.add_user('Поменяй ответственного задачи.')

    output = described_class.new(
      expected: { require_assistant_response_after_last_user: true }
    ).call(input_for(state))

    expect(output.verdict).to eq('failure')
    expect(output.reasoning).to include('assistant response missing')
    expect(output.events.first).to include(action: 'judge_evaluation', verdict: 'failure')
  end

  it 'passes deterministically when expected scenario checks pass' do
    state = Llm::Evals::Scenario::State.new
    state.add_user('Удвой сумму сделки.')
    state.add_assistant('Готово, сумма обновлена.')

    output = described_class.new(
      expected: { require_assistant_response_after_last_user: true }
    ).call(input_for(state))

    expect(output.verdict).to eq('success')
    expect(output.reasoning).to eq('Scenario expectations passed.')
  end

  it 'sends compact state, trace digest, and schema to an injected judge client' do
    requests = []
    client = lambda do |request|
      requests << request
      {
        verdict: 'success',
        reasoning: 'Tool result was used in the final answer.',
        passed_criteria: ['final_answer']
      }
    end

    state = Llm::Evals::Scenario::State.new
    state.add_user('Найди сделку Хлопок.')
    state.add_tool_event('tool_completed', name: 'search_deals', result: { title: 'Хлопок', token: 'secret' })
    state.add_assistant('Нашел сделку Хлопок.')

    output = described_class.new(
      criteria: ['Assistant must answer after using the tool result.'],
      client: client
    ).call(input_for(state))

    expect(output.verdict).to eq('success')
    expect(requests.first).to include(:thread_id, :messages, :new_messages, :tool_events, :state_summary, :trace_digest, :response_schema, :tools)
    expect(requests.first[:tool_events].first.dig(:result, :token)).to eq('[REDACTED]')
    expect(requests.first[:response_schema].dig(:properties, :verdict, :enum)).to include('success', 'failure')
  end

  it 'uses trace events from the scenario input when explicit trace events are not provided' do
    requests = []
    client = lambda do |request|
      requests << request
      { verdict: 'continue', reasoning: 'Need another turn.' }
    end
    state = Llm::Evals::Scenario::State.new
    state.add_user('Проверь OpenRouter.')

    described_class.new(criteria: ['Inspect trace.'], client: client).call(
      input_for(
        state,
        trace_events: [
          { event_name: 'llm.chat.complete', payload: { openrouter_generation_id: 'gen_123', total_tokens: 11 } }
        ]
      )
    )

    expect(requests.first.dig(:trace_digest, :openrouter_generation_ids)).to eq(['gen_123'])
    expect(requests.first.dig(:trace_digest, :token_totals, :total_tokens)).to eq(11)
  end

  it 'keeps malformed judge client responses inconclusive instead of raising' do
    state = Llm::Evals::Scenario::State.new
    state.add_user('Проверь диалог.')

    output = described_class.new(
      criteria: ['Return JSON only.'],
      client: ->(_request) { 'plain text' }
    ).call(input_for(state))

    expect(output.verdict).to eq('inconclusive')
    expect(output.reasoning).to eq('Judge client returned non-JSON text.')
  end

  it 'can replay a cached judge response without a live client' do
    store = ActiveSupport::Cache::MemoryStore.new
    state = Llm::Evals::Scenario::State.new
    state.add_user('Проверь итог.')

    live_agent = described_class.new(
      criteria: ['Must be safe.'],
      client: ->(_request) { { verdict: 'success', reasoning: 'cached verdict' } },
      cache_key: 'judge-replay',
      cache_store: store
    )
    live_agent.call(input_for(state))

    replay_agent = described_class.new(
      criteria: ['Must be safe.'],
      cache_key: 'judge-replay',
      cache_store: store,
      cache_mode: :read_only
    )
    replay_output = replay_agent.call(input_for(state))

    expect(replay_output.verdict).to eq('success')
    expect(replay_output.reasoning).to eq('cached verdict')
  end

  it 'allows scenario scripts to call the judge adapter explicitly' do
    result = Llm::Evals::Scenario::Runner.new(
      id: 'judge.call',
      script: [
        { user: 'Проверь итог.' },
        { assistant: 'Итог готов.' },
        { judge: { call: true } }
      ],
      expected: {},
      agents: [
        described_class.new(
          expected: { require_assistant_response_after_last_user: true }
        )
      ]
    ).call

    expect(result.to_case_result).to include(status: 'pass', reasoning: 'Scenario expectations passed.')
    expect(result.state.event_names).to include('scenario.judge.evaluation')
  end

  def input_for(state, trace_events: [])
    Llm::Evals::Scenario::AgentAdapter::Input.new(
      thread_id: state.thread_id,
      messages: state.messages,
      new_messages: state.messages,
      state: state,
      fixtures: {},
      account: nil,
      trace_events: trace_events
    )
  end
end
