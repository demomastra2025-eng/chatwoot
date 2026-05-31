# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Llm::Evals::Scenario::UserSimulatorAgent do
  it 'emits scripted user messages in order for deterministic simulations' do
    adapter = described_class.new(scripted_messages: ['первый вопрос', 'подтверждаю'])
    state = Llm::Evals::Scenario::State.new

    first_output = adapter.call(input_for(state))
    state.add_user(first_output.messages.first)
    second_output = adapter.call(input_for(state))

    expect(first_output.messages.first).to include(role: 'user', content: 'первый вопрос')
    expect(second_output.messages.first).to include(role: 'user', content: 'подтверждаю')
    expect(first_output.events.first).to include(action: 'user_simulator_message', source: 'scripted')
  end

  it 'builds a role-reversed request for an injected simulator client' do
    requests = []
    client = lambda do |request|
      requests << request
      { content: 'а кто ответственный сейчас?' }
    end
    state = Llm::Evals::Scenario::State.new
    state.add_user('измени задачу token=secret')
    state.add_assistant('Уточните, на кого назначить?')

    output = described_class.new(
      description: 'Проверить смену ответственного задачи',
      persona: 'Коротко отвечает и подтверждает действия.',
      client: client
    ).call(input_for(state))

    expect(output.messages.first).to include(role: 'user', content: 'а кто ответственный сейчас?')
    expect(output.events.first).to include(source: 'client')
    expect(requests.first[:messages]).to include(
      hash_including(role: 'assistant', content: 'измени задачу token=[REDACTED]'),
      hash_including(role: 'user', content: 'Уточните, на кого назначить?')
    )
    expect(requests.first[:system_prompt]).to include('Scenario: Проверить смену ответственного задачи')
  end

  it 'accepts plain text client responses for lightweight adapters' do
    state = Llm::Evals::Scenario::State.new
    output = described_class.new(client: ->(_request) { 'да, подтверждаю' }).call(input_for(state))

    expect(output.messages.first).to include(content: 'да, подтверждаю')
  end

  it 'can replay cached simulator messages without a live client' do
    store = ActiveSupport::Cache::MemoryStore.new
    state = Llm::Evals::Scenario::State.new
    state.add_assistant('Нужно подтверждение.')

    live_agent = described_class.new(
      client: ->(_request) { { content: 'подтверждаю' } },
      cache_key: 'user-replay',
      cache_store: store
    )
    live_agent.call(input_for(state))

    replay_agent = described_class.new(
      cache_key: 'user-replay',
      cache_store: store,
      cache_mode: :read_only
    )
    output = replay_agent.call(input_for(state))

    expect(output.messages.first).to include(role: 'user', content: 'подтверждаю')
  end

  it 'drives proceed loops together with agent and judge adapters' do
    agent = Class.new(Llm::Evals::Scenario::AgentAdapter) do
      def initialize
        super(role: :agent, name: 'EchoAgent')
      end

      def call(input)
        { messages: [{ content: "Ответ: #{input.new_messages.last[:content]}" }] }
      end
    end.new

    result = Llm::Evals::Scenario::Runner.new(
      id: 'user_simulator.proceed',
      script: [{ proceed: { turns: 1 } }],
      expected: { require_assistant_response_after_last_user: true, require_answer_fragments: ['подтверждаю'] },
      agents: [
        described_class.new(scripted_messages: ['подтверждаю']),
        agent,
        Llm::Evals::Scenario::JudgeAgent.new(
          expected: { require_assistant_response_after_last_user: true },
          terminal_on_pass: false
        )
      ]
    ).call

    expect(result.to_case_result).to include(status: 'pass')
    expect(result.state.event_names).to include('scenario.user_simulator.message', 'scenario.judge.evaluation')
  end

  def input_for(state)
    Llm::Evals::Scenario::AgentAdapter::Input.new(
      thread_id: state.thread_id,
      messages: state.messages,
      new_messages: state.messages,
      state: state,
      fixtures: {},
      account: nil
    )
  end
end
