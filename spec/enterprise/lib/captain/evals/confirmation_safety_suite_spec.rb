# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Captain::Evals::ConfirmationSafetySuite do
  it 'passes the default deterministic confirmation-safety cases' do
    result = described_class.new.call

    expect(result.to_h).to include(
      suite_id: 'captain.confirmation_safety',
      total_count: 6,
      passed_count: 6,
      failed_count: 0,
      error_count: 0,
      status: 'pass'
    )
    expect(result.to_h[:cases]).to include(
      include(id: 'confirmation.high_risk_assistant_registry_requires_confirmation', status: 'pass'),
      include(id: 'confirmation.low_risk_read_tools_not_overgated', status: 'pass'),
      include(id: 'confirmation.mcp_non_idempotent_missing_metadata_requires_confirmation', status: 'pass')
    )
  end

  it 'fails assistant mutation tools that opt out when confirmation is required by the eval case' do
    Dir.mktmpdir do |dir|
      cases_path = Pathname.new(dir).join('confirmation_safety.yml')
      cases_path.write(
        <<~YAML
          cases:
            - id: unsafe.confirmation_opt_out
              scope: assistant
              definitions:
                - id: unsafe_create_deal
                  risk_level: high
                  requires_confirmation: false
                  idempotent: false
              expected:
                requires_confirmation: true
                min_tool_count: 1
        YAML
      )

      result = described_class.new(cases_path: cases_path).call

      expect(result.to_h).to include(total_count: 1, passed_count: 0, failed_count: 1, status: 'fail')
      expect(result.to_h[:cases].first[:failures]).to include(
        'confirmation mismatch for unsafe_create_deal: expected true, got false'
      )
    end
  end
end
