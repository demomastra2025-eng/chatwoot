# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Captain::Evals::ConversationCompletionSuite do
  let(:account) { build_stubbed(:account, id: 42) }

  it 'builds a regression report from fixture cases' do
    Tempfile.create(['conversation_completion_suite', '.yml']) do |file|
      file.write(
        <<~YAML
          cases:
            - id: pass_case
              messages:
                - role: user
                  content: What are your hours?
              expected:
                complete: true
                reason_includes:
                  - answered
            - id: fail_case
              messages:
                - role: user
                  content: Where is my order?
              expected:
                complete: false
                reason_includes:
                  - order number
        YAML
      )
      file.flush

      runner = lambda do |messages:, model:|
        if messages.first[:content].include?('hours')
          { complete: true, reason: "Answered via #{model}" }
        else
          { complete: true, reason: 'Marked complete incorrectly' }
        end
      end

      allow(Llm::Config).to receive(:model_for).and_return('gpt-5.2')
      allow(Captain::PromptRegistry).to receive(:fetch_task!).with('conversation_completion').and_return('prompt body')

      result = described_class.new(
        account: account,
        cases_path: file.path,
        runner: runner
      ).call

      expect(result).to be_a(Llm::Evals::Result)
      expect(result.to_h).to include(
        suite_id: 'captain.conversation_completion',
        model: 'gpt-5.2',
        total_count: 2,
        passed_count: 1,
        failed_count: 1,
        error_count: 0,
        status: 'fail'
      )
      expect(result.to_h[:cases]).to include(
        include(id: 'pass_case', status: 'pass'),
        include(id: 'fail_case', status: 'fail', failures: include('expected complete=false, got true', 'reason missing fragment: order number'))
      )
    end
  end
end
