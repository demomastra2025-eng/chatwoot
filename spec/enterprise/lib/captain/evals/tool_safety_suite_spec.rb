# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Captain::Evals::ToolSafetySuite do
  it 'evaluates deterministic tool safety cases from fixtures' do
    Tempfile.create(['tool_safety_suite', '.yml']) do |file|
      file.write(
        <<~YAML
          cases:
            - id: blocked_arguments
              kind: arguments
              feature: assistant
              content:
                secret: payroll record
              preferences:
                assistant_safety_blocklist:
                  - payroll record
              expected:
                status: blocked
                reason: custom_blocklist
                rule: payroll record
                blocked_message_includes:
                  - Tool arguments blocked
            - id: unavailable_results
              kind: results
              feature: assistant
              content: outbound payload
              provider_mode: unavailable
              preferences:
                assistant_moderation: true
                moderation_failure_mode: fail_closed
              expected:
                status: unavailable
                reason: provider_not_configured
                blocked_message_includes:
                  - safety policy is unavailable
        YAML
      )
      file.flush

      result = described_class.new(cases_path: file.path).call

      expect(result.to_h).to include(
        suite_id: 'captain.tool_safety',
        total_count: 2,
        passed_count: 2,
        failed_count: 0,
        error_count: 0,
        status: 'pass'
      )
    end
  end
end
