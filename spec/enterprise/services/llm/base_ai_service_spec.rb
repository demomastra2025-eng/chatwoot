require 'rails_helper'

RSpec.describe Llm::BaseAiService do
  subject(:service) { described_class.new }

  before do
    upsert_installation_config('CAPTAIN_OPEN_AI_API_KEY', 'test-key')
  end

  describe '#sanitize_json_response' do
    it 'strips ```json fences' do
      input = "```json\n{\"key\": \"value\"}\n```"
      expect(service.send(:sanitize_json_response, input)).to eq('{"key": "value"}')
    end

    it 'strips bare ``` fences' do
      input = "```\n{\"key\": \"value\"}\n```"
      expect(service.send(:sanitize_json_response, input)).to eq('{"key": "value"}')
    end

    it 'passes through plain JSON unchanged' do
      input = '{"key": "value"}'
      expect(service.send(:sanitize_json_response, input)).to eq('{"key": "value"}')
    end

    it 'returns nil for nil input' do
      expect(service.send(:sanitize_json_response, nil)).to be_nil
    end

    it 'strips surrounding whitespace' do
      input = "  \n{\"key\": \"value\"}\n  "
      expect(service.send(:sanitize_json_response, input)).to eq('{"key": "value"}')
    end
  end

  describe '#chat' do
    let(:chat) { instance_double(RubyLLM::Chat) }

    it 'delegates chat construction to Llm::ChatClient' do
      expect(Llm::ChatClient).to receive(:build).with(model: service.model, temperature: service.temperature).and_return(chat)

      expect(service.chat).to eq(chat)
    end
  end
end
