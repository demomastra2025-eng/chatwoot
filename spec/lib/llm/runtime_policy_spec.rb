# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Llm::RuntimePolicy do
  let(:account) { create(:account) }

  describe '.thinking_options' do
    it 'returns nil when thinking is disabled' do
      expect(
        described_class.thinking_options(feature: :assistant, account: account, model: 'gpt-5.1')
      ).to be_nil
    end

    it 'returns effort for supported models' do
      account.update!(captain_runtime: { 'assistant_thinking_effort' => 'high' })

      expect(
        described_class.thinking_options(feature: :assistant, account: account, model: 'gpt-5.1')
      ).to eq(effort: 'high')
    end

    it 'adds a budget for anthropic models' do
      account.update!(captain_runtime: { 'assistant_thinking_effort' => 'medium' })

      expect(
        described_class.thinking_options(feature: :assistant, account: account, model: 'claude-sonnet-4.5')
      ).to eq(effort: 'medium', budget: 4096)
    end
  end

  describe '.moderation_enabled?' do
    it 'reads moderation flags from runtime preferences' do
      account.update!(captain_runtime: { 'copilot_moderation' => true })

      expect(described_class.moderation_enabled?(feature: :copilot, account: account)).to be true
      expect(described_class.moderation_enabled?(feature: :assistant, account: account)).to be false
    end
  end
end
