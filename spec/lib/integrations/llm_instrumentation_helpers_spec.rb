# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Integrations::LlmInstrumentationHelpers do
  subject(:helper) { helper_class.new }

  let(:helper_class) do
    Class.new do
      include Integrations::LlmInstrumentationHelpers
    end
  end

  describe '#determine_provider' do
    it 'does not invent OpenAI for blank or unknown models' do
      expect(helper.determine_provider(nil)).to be_nil
      expect(helper.determine_provider('')).to be_nil
      expect(helper.determine_provider('unknown-model')).to be_nil
    end

    it 'uses the LLM config resolver before prefix heuristics' do
      allow(Llm::Config).to receive(:provider_for_model).with('openai/gpt-5.4').and_return('openrouter')

      expect(helper.determine_provider('openai/gpt-5.4')).to eq('openrouter')
    end

    it 'keeps optional providers attributed by explicit prefixes' do
      expect(helper.determine_provider('claude-sonnet-4-6')).to eq('anthropic')
      expect(helper.determine_provider('gemini-2.5-pro')).to eq('gemini')
    end
  end
end
