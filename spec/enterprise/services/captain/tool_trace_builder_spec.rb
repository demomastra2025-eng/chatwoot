require 'rails_helper'

RSpec.describe Captain::ToolTraceBuilder do
  describe '.step' do
    it 'builds a canonical trace step with input and output details' do
      expect(
        described_class.step(
          tool_name: 'search_documentation',
          event: 'finish',
          sequence: 1,
          input: { query: 'apartments', api_token: 'x' },
          output: { total: 2 }
        )
      ).to eq(
        {
          'id' => 'search_documentation:finish:1',
          'type' => 'captain_tool_event',
          'tool_name' => 'search_documentation',
          'event' => 'finish',
          'status' => 'finish',
          'content' => 'Completed search_documentation',
          'input' => { 'query' => 'apartments', 'api_token' => '[REDACTED]' },
          'output' => { 'total' => 2 }
        }
      )
    end

    it 'keeps tool call identifiers sequence-safe for repeated progress events' do
      expect(
        described_class.step(
          tool_name: 'search_documentation',
          event: 'progress',
          sequence: 3,
          tool_call_id: 'call-1'
        )
      ).to include('id' => 'search_documentation:progress:3:call-1')
    end

    it 'keeps legacy complete events readable as finish status' do
      expect(
        described_class.step(
          tool_name: 'search_documentation',
          event: 'complete',
          sequence: 2
        )
      ).to include(
        'event' => 'complete',
        'status' => 'finish',
        'content' => 'Completed search_documentation'
      )
    end
  end

  describe '.payload' do
    it 'wraps steps into a stable captain trace payload' do
      steps = [
        described_class.step(
          tool_name: 'search_documentation',
          event: 'complete',
          sequence: 2
        )
      ]

      expect(described_class.payload(steps)).to eq(
        {
          'version' => 1,
          'tool_steps' => steps
        }
      )
    end

    it 'returns nil when there are no steps' do
      expect(described_class.payload([])).to be_nil
    end
  end
end
