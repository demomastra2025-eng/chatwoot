require 'rails_helper'

RSpec.describe Llm::BaseAiService do
  subject(:service) { described_class.new }

  before do
    upsert_installation_config('CAPTAIN_OPEN_AI_API_KEY', 'test-key')
  end

  describe '#chat' do
    let(:chat) { instance_double(RubyLLM::Chat) }

    it 'delegates chat construction to Llm::ChatClient' do
      expect(Llm::ChatClient).to receive(:build).with(model: service.model, temperature: service.temperature).and_return(chat)

      expect(service.chat).to eq(chat)
    end
  end

  describe '#ask_chat' do
    let(:chat) { instance_double(RubyLLM::Chat) }

    it 'delegates asking to Llm::ChatClient' do
      expect(Llm::ChatClient).to receive(:ask).with(chat, 'hello')

      service.send(:ask_chat, chat, 'hello')
    end
  end
end
