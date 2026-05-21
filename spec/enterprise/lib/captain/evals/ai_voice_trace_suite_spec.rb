# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Captain::Evals::AiVoiceTraceSuite do
  it 'passes voice traces where the answer uses a completed tool result' do
    Tempfile.create(['ai_voice_trace_suite', '.yml']) do |file|
      file.write(
        <<~YAML
          cases:
            - id: deal_price_answer
              events:
                - action: caller_transcript_final
                  content: Сколько стоит сделка?
                - action: tool_completed
                  tool_name: search_deals
                  result:
                    ok: true
                    content: "Сделка #481, цена 250 000 ₸"
                - action: ai_transcript_turn
                  role: ai
                  content: "По сделке #481 цена 250 000 ₸."
              expected:
                require_actions:
                  - tool_completed
                  - ai_transcript_turn
                forbid_actions:
                  - pacer_drop
                require_tool_result_usage:
                  - tool: search_deals
                    fragment: "250 000"
        YAML
      )
      file.flush

      result = described_class.new(cases_path: file.path).call

      expect(result.to_h).to include(
        suite_id: 'captain.ai_voice_trace',
        total_count: 1,
        passed_count: 1,
        failed_count: 0,
        error_count: 0,
        status: 'pass'
      )
    end
  end

  it 'fails traces with clipped output and unused completed tool data' do
    Tempfile.create(['ai_voice_trace_suite_bad', '.yml']) do |file|
      file.write(
        <<~YAML
          cases:
            - id: clipped_unused_tool_result
              events:
                - action: tool_completed
                  tool_name: search_deals
                  result:
                    ok: true
                    content: Цена 250 000 ₸
                - action: pacer_drop
                  reason: overflow
                - action: ai_transcript_turn
                  role: ai
                  content: Я нашла сделку, цена...
              expected:
                forbid_actions:
                  - pacer_drop
                require_tool_result_usage:
                  - tool: search_deals
                    fragment: "250 000"
        YAML
      )
      file.flush

      result = described_class.new(cases_path: file.path).call

      expect(result.to_h).to include(
        suite_id: 'captain.ai_voice_trace',
        total_count: 1,
        passed_count: 0,
        failed_count: 1,
        status: 'fail'
      )
      expect(result.to_h[:cases].first[:failures]).to include(
        'forbidden action present: pacer_drop',
        'tool result fragment was not used after search_deals: 250 000'
      )
    end
  end
end
