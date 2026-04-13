# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Llm::Evals::CaseLoader do
  it 'loads and normalizes eval cases from yaml' do
    Tempfile.create(['conversation_completion', '.yml']) do |file|
      file.write(
        <<~YAML
          cases:
            - id: basic_case
              tags: [foo, bar]
              messages:
                - role: user
                  content: Hello
                - role: assistant
                  content: Hi there
              expected:
                complete: true
                reason_includes:
                  - answered
        YAML
      )
      file.flush

      result = described_class.new(path: file.path).load

      expect(result).to eq(
        [
          {
            id: 'basic_case',
            tags: %w[foo bar],
            input: {
              messages: [
                { role: 'user', content: 'Hello' },
                { role: 'assistant', content: 'Hi there' }
              ]
            },
            expected: {
              complete: true,
              reason_includes: ['answered']
            }
          }
        ]
      )
    end
  end
end
