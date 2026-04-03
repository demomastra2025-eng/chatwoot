require 'rails_helper'

RSpec.describe Captain::ToolTraceBuilder do
  describe '.step' do
    it 'builds a normalized trace step' do
      expect(
        described_class.step(
          tool_name: 'search_documentation',
          event: 'start',
          sequence: 1
        )
      ).to eq(
        {
          'id' => 'search_documentation:start:1',
          'tool_name' => 'search_documentation',
          'event' => 'start',
          'content' => 'Using search_documentation'
        }
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
