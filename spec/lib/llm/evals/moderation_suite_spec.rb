# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Llm::Evals::ModerationSuite do
  it 'evaluates moderation edge cases from fixtures without network access' do
    Tempfile.create(['moderation_suite', '.yml']) do |file|
      file.write(
        <<~YAML
          cases:
            - id: unavailable
              feature: assistant
              stage: input
              content: Hello
              provider_mode: unavailable
              preferences:
                assistant_moderation: true
                moderation_failure_mode: fail_closed
              expected:
                status: unavailable
                reason: provider_not_configured
            - id: flagged
              feature: assistant
              stage: output
              content: Unsafe response
              provider_mode: flagged
              preferences:
                assistant_moderation: true
              expected:
                status: flagged
                reason: moderation_flagged
        YAML
      )
      file.flush

      result = described_class.new(cases_path: file.path).call

      expect(result.to_h).to include(
        suite_id: 'llm.moderation',
        total_count: 2,
        passed_count: 2,
        failed_count: 0,
        error_count: 0,
        status: 'pass'
      )
    end
  end
end
