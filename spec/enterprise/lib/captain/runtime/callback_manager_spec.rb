# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Captain::Runtime::CallbackManager do
  describe '#listening?' do
    it 'tells whether anything is registered for the event' do
      manager = described_class.new(answer_delta: [->(*) {}], tool_start: [])

      expect(manager.listening?(:answer_delta)).to be(true)
      expect(manager.listening?(:tool_start)).to be(false)
      expect(manager.listening?(:run_start)).to be(false)
    end
  end

  describe '#emit_answer_delta' do
    it 'hands the agent, the text and the run to the listeners' do
      calls = []
      manager = described_class.new(answer_delta: [->(agent, text, run) { calls << [agent, text, run] }])

      manager.emit_answer_delta('Диана', 'Здравст', :run)

      expect(calls).to eq([['Диана', 'Здравст', :run]])
    end
  end
end
