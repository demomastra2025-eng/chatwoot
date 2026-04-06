# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Captain::Assistant::PromptPreviewService do
  let(:account) { create(:account) }
  let(:assistant) { create(:captain_assistant, account: account, description: 'Handle billing questions only.') }

  describe '#preview' do
    it 'builds assistant and copilot previews from the unified instruction contract' do
      preview = described_class.new(assistant: assistant).preview

      expect(preview.dig(:assistant, :layers)).to include(
        include(id: 'instruction', title: 'System instruction', enabled: true, value: 'Handle billing questions only.')
      )
      expect(preview.dig(:copilot, :layers)).to include(
        include(id: 'assistant_instruction', title: 'System instruction', enabled: true, value: 'Handle billing questions only.')
      )
    end

    it 'uses assistant tool access when building the copilot preview summary' do
      assistant.update!(
        config: assistant.config.merge(
          'tool_access' => {
            'assistant' => {
              'enabled' => true,
              'tool_ids' => ['search_documentation']
            }
          }
        )
      )

      preview = described_class.new(assistant: assistant).preview

      expect(preview.dig(:copilot, :used_tool_ids)).to eq(['search_documentation'])
      expect(preview.dig(:copilot, :compiled_prompt)).to include('search_documentation')
      expect(preview.dig(:copilot, :compiled_prompt)).not_to include('faq_lookup')
    end

    it 'builds preview metadata when rules and restrictions are stored as arrays' do
      assistant.update!(
        description: 'Start with [Name](field://contact.name).',
        response_guidelines: ['Use [FAQ Lookup](tool://faq_lookup) before replying.'],
        guardrails: ['Never expose [Conversation ID](field://conversation.display_id) to the customer.']
      )

      preview = described_class.new(assistant: assistant).preview

      expect(preview.dig(:assistant, :used_tool_ids)).to eq(['faq_lookup'])
      expect(preview.dig(:assistant, :used_field_ids)).to contain_exactly(
        'contact.name',
        'conversation.display_id'
      )
    end
  end
end
