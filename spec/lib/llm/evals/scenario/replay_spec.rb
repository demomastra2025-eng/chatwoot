# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Llm::Evals::Scenario::Replay do
  it 'replays persisted-style events through the shared scenario expectations' do
    result = described_class.new(
      id: 'replay.tool_final_answer',
      messages: [{ role: 'user', content: 'Найди сумму сделки.' }],
      events: [
        {
          event_name: 'llm.tool.complete',
          tool_name: 'search_deals',
          payload: { result: { amount: 125_000 } }
        },
        {
          event_name: 'llm.run.complete',
          payload: { response: 'Сумма сделки 125000 KZT.' }
        }
      ],
      expected: {
        require_tools: ['search_deals'],
        require_assistant_response_after_last_user: true,
        require_tool_result_usage: [{ tool: 'search_deals', fragment: '125000' }]
      }
    ).call

    expect(result.to_case_result).to include(status: 'pass')
  end

  it 'fails replay when the tool completes but no final assistant answer is present' do
    result = described_class.new(
      id: 'replay.missing_final_answer',
      messages: [{ role: 'user', content: 'Найди сумму сделки.' }],
      events: [
        {
          event_name: 'llm.tool.complete',
          tool_name: 'search_deals',
          payload: { result: { amount: 125_000 } }
        }
      ],
      expected: {
        require_tools: ['search_deals'],
        require_assistant_response_after_last_user: true,
        require_tool_result_usage: [{ tool: 'search_deals', fragment: '125000' }]
      }
    ).call

    expect(result.to_case_result).to include(status: 'fail')
    expect(result.to_case_result[:failures]).to include(
      'assistant response missing after last user message',
      'tool result fragment was not used after search_deals: 125000'
    )
  end

  it 'replays deterministic OpenRouter metadata without constructing a live OpenRouter client' do
    expect(Llm::Evals::OpenRouterClient).not_to receive(:new)

    result = described_class.new(
      id: 'replay.openrouter_structured_healing',
      messages: [{ role: 'user', content: 'Сформируй JSON ответ.' }],
      events: [
        {
          event_name: 'llm.schema.invalid',
          payload: {
            schema_invalid: true,
            model: 'openai/gpt-5.4-mini',
            fallback_model: 'openai/gpt-5.4-mini-high'
          }
        },
        {
          event_name: 'llm.run.complete',
          payload: {
            response: 'Готово, структурированный ответ восстановлен.',
            reasoning: 'Healed invalid structured output.',
            openrouter_generation_id: 'gen_replay_123'
          }
        }
      ],
      expected: {
        require_event_names: ['llm.schema.invalid'],
        require_event_fragments: [{ event: 'llm.schema.invalid', fragment: 'fallback_model' }],
        require_assistant_response_after_last_user: true,
        require_reasoning_present: true,
        require_openrouter_generation_id: true
      }
    ).call

    expect(result.to_case_result).to include(status: 'pass')
  end
end
