# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Llm::Evals::Scenario::Artifact do
  it 'packages scenario result with a sanitized trace digest' do
    result = Llm::Evals::Scenario::Runner.new(
      id: 'artifact.case',
      script: [{ user: 'Привет' }, { assistant: 'Здравствуйте' }],
      expected: { require_assistant_response_after_last_user: true }
    ).call

    artifact = described_class.build(
      result: result,
      trace_events: [{ event_name: 'llm.chat.complete', payload: { token: 'secret', response: 'ok' } }]
    )

    expect(artifact).to include(case_id: 'artifact.case', status: 'pass')
    expect(artifact[:summary]).to include(turn_count: 2, tool_events_count: 0)
    expect(artifact[:timeline]).to include(
      include(type: 'message', role: 'user', preview: 'Привет'),
      include(type: 'message', role: 'assistant', preview: 'Здравствуйте')
    )
    expect(artifact).not_to include(:actual)
    expect(artifact.dig(:trace_digest, :events, 0, :payload)).to include(token: '[REDACTED]')
  end
end
