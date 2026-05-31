# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Llm::Evals::Scenario::Runner do
  it 'passes a scripted multi-turn tool scenario when the final answer uses the completed tool result' do
    result = described_class.new(
      id: 'crm.lookup',
      script: [
        { user: 'Найди сделку Алия.' },
        { tool_completed: { name: 'search_deals', result: { title: 'Алия', amount: 125_000 } } },
        { assistant: 'Нашла сделку Алия на сумму 125000 KZT.' },
        { judge: {} }
      ],
      expected: {
        require_tools: ['search_deals'],
        require_assistant_response_after_last_user: true,
        require_tool_result_usage: [{ tool: 'search_deals', fragment: '125000' }]
      }
    ).call

    expect(result.to_case_result).to include(status: 'pass')
    expect(result.to_case_result[:actual]).to include(
      turn_count: 2,
      ui_action_types: []
    )
  end

  it 'fails when a mutating tool is executed twice for the same idempotency key' do
    result = described_class.new(
      id: 'crm.duplicate_mutation',
      script: [
        { user: 'Удвой сумму сделки Хлопок.' },
        { user: 'Подтверждаю.' },
        {
          tool_completed: {
            name: 'update_deal',
            mutation: true,
            resource_type: 'deal',
            resource_id: 533,
            idempotency_key: 'deal-533-double',
            result: { amount_after: 180_000 }
          }
        },
        {
          tool_completed: {
            name: 'update_deal',
            mutation: true,
            resource_type: 'deal',
            resource_id: 533,
            idempotency_key: 'deal-533-double',
            result: { amount_after: 360_000 }
          }
        },
        { assistant: 'Готово, сумма обновлена.' }
      ],
      expected: {
        require_tools: ['update_deal'],
        forbid_duplicate_mutations: true
      }
    ).call

    expect(result.to_case_result).to include(status: 'fail')
    expect(result.to_case_result[:failures].join(' ')).to include('duplicate mutations present')
  end

  it 'lets an agent adapter consume only new messages and append an assistant response' do
    adapter_class = Class.new(Llm::Evals::Scenario::AgentAdapter) do
      attr_reader :seen_new_messages

      def initialize
        super(role: :agent, name: 'SpecAgent')
        @seen_new_messages = []
      end

      def call(input)
        @seen_new_messages << input.new_messages.pluck(:content)
        { messages: [{ content: "Ответ на: #{input.new_messages.last[:content]}" }] }
      end
    end
    adapter = adapter_class.new

    result = described_class.new(
      id: 'adapter.basic',
      script: [
        { user: 'Первый вопрос' },
        { agent: { call: true } },
        { user: 'Второй вопрос' },
        { agent: { call: true } }
      ],
      expected: {
        require_assistant_response_after_last_user: true,
        require_answer_fragments: ['Второй вопрос']
      },
      agents: [adapter]
    ).call

    expect(result.to_case_result).to include(status: 'pass')
    expect(adapter.seen_new_messages).to eq([['Первый вопрос'], ['Второй вопрос']])
  end

  it 'can run an explicit autopilot simulation without a hand-written script' do
    agent = Class.new(Llm::Evals::Scenario::AgentAdapter) do
      def initialize
        super(role: :agent, name: 'SpecAgent')
      end

      def call(input)
        { messages: [{ content: "Принял: #{input.new_messages.last[:content]}" }] }
      end
    end.new

    result = described_class.new(
      id: 'autopilot.basic',
      autopilot: true,
      autopilot_turns: 1,
      expected: {
        require_assistant_response_after_last_user: true,
        require_answer_fragments: ['запиши лид']
      },
      agents: [
        Llm::Evals::Scenario::UserSimulatorAgent.new(scripted_messages: ['запиши лид']),
        agent,
        Llm::Evals::Scenario::JudgeAgent.new(
          expected: { require_assistant_response_after_last_user: true },
          terminal_on_pass: false
        )
      ]
    ).call

    expect(result.to_case_result).to include(status: 'pass')
  end
end
