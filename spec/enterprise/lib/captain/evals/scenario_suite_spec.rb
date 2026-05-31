# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Captain::Evals::ScenarioSuite do
  it 'passes the default deterministic Captain scenario simulations' do
    result = described_class.new.call

    expect(result.to_h).to include(
      suite_id: 'captain.scenarios',
      total_count: 8,
      passed_count: 8,
      failed_count: 0,
      error_count: 0,
      status: 'pass'
    )
    expect(result.to_h[:cases]).to include(
      include(id: 'support.tool_result_requires_final_answer', status: 'pass'),
      include(id: 'crm.double_deal_amount_after_confirmation', status: 'pass'),
      include(id: 'crm.change_task_assignee_after_confirmation', status: 'pass'),
      include(id: 'scenario.routing_handoff_stays_visible', status: 'pass'),
      include(id: 'openrouter.structured_output_healing', status: 'pass'),
      include(id: 'openrouter.tool_result_requires_final_answer', status: 'pass'),
      include(id: 'openrouter.fallback_model_recorded', status: 'pass'),
      include(id: 'openrouter.reasoning_presence', status: 'pass')
    )
  end

  it 'fails when a completed tool result is not followed by a final answer' do
    Dir.mktmpdir do |dir|
      cases_path = Pathname.new(dir).join('captain_scenarios.yml')
      cases_path.write(
        <<~YAML
          cases:
            - id: unsafe.tool_without_final_answer
              description: A tool result alone is not enough; Captain must answer the user.
              tags: [tool_result, final_answer]
              script:
                - user: "Найди сделку Алия."
                - tool_completed:
                    name: search_deals
                    result:
                      title: "Алия"
                      amount: 125000
              expected:
                require_tools: [search_deals]
                require_assistant_response_after_last_user: true
                require_tool_result_usage:
                  - tool: search_deals
                    fragment: "125000"
        YAML
      )

      result = described_class.new(cases_path: cases_path).call

      expect(result.to_h).to include(total_count: 1, passed_count: 0, failed_count: 1, status: 'fail')
      expect(result.to_h[:cases].first[:failures].join(' ')).to include(
        'assistant response missing after last user message',
        'tool result fragment was not used after search_deals: 125000'
      )
    end
  end

  it 'fails OpenRouter metadata expectations when the required fallback model fragment is absent' do
    Dir.mktmpdir do |dir|
      cases_path = Pathname.new(dir).join('captain_scenarios.yml')
      cases_path.write(
        <<~YAML
          cases:
            - id: openrouter.missing_fallback_model
              description: OpenRouter fallback events must record the fallback model id.
              tags: [openrouter, routing, fallback_model]
              script:
                - user: "Проверь маршрут модели."
                - message:
                    event_name: llm.openrouter.fallback
                    model: openai/gpt-5.4-mini
                - assistant:
                    content: "Готово, fallback применён."
              expected:
                require_event_names: [llm.openrouter.fallback]
                require_event_fragments:
                  - event: llm.openrouter.fallback
                    fragment: openai/gpt-5.4-mini-high
                require_assistant_response_after_last_user: true
        YAML
      )

      result = described_class.new(cases_path: cases_path).call

      expect(result.to_h).to include(total_count: 1, passed_count: 0, failed_count: 1, status: 'fail')
      expect(result.to_h[:cases].first[:failures]).to include(
        'event llm.openrouter.fallback missing fragment: openai/gpt-5.4-mini-high'
      )
    end
  end
end
