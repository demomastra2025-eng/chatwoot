# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Captain::Evals::Scenario::CaptainAgentAdapter do
  let(:assistant) { instance_double(Captain::Assistant) }
  let(:service) { instance_double(Captain::Assistant::AgentRunnerService, generate_response: runner_response) }
  let(:factory) { ->(**_kwargs) { service } }
  let(:adapter) { described_class.new(assistant: assistant, runner_service_factory: factory) }
  let(:input) do
    Llm::Evals::Scenario::AgentAdapter::Input.new(
      thread_id: 'thread-1',
      messages: [{ role: 'user', content: 'Удвой сумму сделки Хлопок.' }],
      new_messages: [],
      state: instance_double(Llm::Evals::Scenario::State),
      fixtures: {},
      account: nil
    )
  end
  let(:runner_response) do
    {
      response: 'Готово, сумма сделки обновлена до 180 000 KZT.',
      reasoning: 'Used completed tool result.',
      agent_name: 'assistant',
      openrouter_generation_id: 'gen_123',
      captain_trace: {
        tool_steps: [
          {
            id: 'update_deal:finish:1',
            tool_name: 'update_deal',
            status: 'finish',
            input: { id: 533 },
            output: { amount_after: 180_000 },
            duration_ms: 42
          }
        ]
      }
    }
  end

  it 'maps Captain runner responses into scenario messages and tool events without live LLM calls' do
    output = adapter.call(input)

    expect(service).to have_received(:generate_response).with(
      message_history: [{ role: 'user', content: 'Удвой сумму сделки Хлопок.' }]
    )
    expect(output.messages).to include(
      include(
        role: 'assistant',
        content: 'Готово, сумма сделки обновлена до 180 000 KZT.',
        reasoning: 'Used completed tool result.',
        openrouter_generation_id: 'gen_123'
      )
    )
    expect(output.events).to include(
      include(
        action: 'tool_completed',
        tool_name: 'update_deal',
        result: { amount_after: 180_000 },
        duration_ms: 42
      ),
      include(action: 'run_complete', event_name: 'llm.run.complete', openrouter_generation_id: 'gen_123')
    )
  end
end
