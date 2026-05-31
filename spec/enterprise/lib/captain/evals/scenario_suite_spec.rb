# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Captain::Evals::ScenarioSuite do
  it 'passes the default deterministic Captain scenario simulations' do
    result = described_class.new.call

    expect(result.to_h).to include(
      suite_id: 'captain.scenarios',
      total_count: 4,
      passed_count: 4,
      failed_count: 0,
      error_count: 0,
      status: 'pass'
    )
    expect(result.to_h[:cases]).to include(
      include(id: 'support.tool_result_requires_final_answer', status: 'pass'),
      include(id: 'crm.double_deal_amount_after_confirmation', status: 'pass'),
      include(id: 'crm.change_task_assignee_after_confirmation', status: 'pass'),
      include(id: 'scenario.routing_handoff_stays_visible', status: 'pass')
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
end
