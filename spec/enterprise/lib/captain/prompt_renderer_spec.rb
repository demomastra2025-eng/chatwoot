# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Captain::PromptRenderer do
  let(:template_name) { 'assistant' }
  let(:context) { { name: 'John', balance: 100 } }

  describe '.render' do
    it 'delegates rendering to the unified prompt registry' do
      allow(Captain::PromptRegistry).to receive(:render!).and_return('rendered prompt')

      result = described_class.render(template_name, context)

      expect(result).to eq('rendered prompt')
      expect(Captain::PromptRegistry).to have_received(:render!).with(template_name, variables: context)
    end

    it 'passes through an empty context without special casing' do
      allow(Captain::PromptRegistry).to receive(:render!).and_return('rendered prompt')

      described_class.render(template_name, {})

      expect(Captain::PromptRegistry).to have_received(:render!).with(template_name, variables: {})
    end
  end
end
