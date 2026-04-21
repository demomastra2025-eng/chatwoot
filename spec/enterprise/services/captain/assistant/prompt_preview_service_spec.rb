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
      expect(preview.dig(:assistant, :layers)).to include(
        include(id: 'system_rules', title: 'System rules', enabled: true)
      )
      expect(preview.dig(:assistant, :used_tool_ids)).to eq(%w[faq_lookup handoff])
      expect(preview.dig(:assistant, :compiled_prompt)).to include('FAQ Lookup (faq_lookup)')
      expect(preview.dig(:assistant, :compiled_prompt)).to include('Handoff to Human (handoff)')
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

      expect(preview.dig(:assistant, :used_tool_ids)).to eq(%w[faq_lookup handoff])
      expect(preview.dig(:assistant, :used_field_ids)).to contain_exactly(
        'contact.name',
        'conversation.display_id'
      )
    end

    it 'includes handoff in the assistant preview when the default capability is enabled' do
      preview = described_class.new(assistant: assistant).preview

      expect(preview.dig(:assistant, :used_tool_ids)).to contain_exactly('faq_lookup', 'handoff')
      expect(preview.dig(:assistant, :compiled_prompt)).to include('Handoff to Human (handoff)')
    end

    it 'reports only runtime-available scenario tools in preview metadata' do
      custom_tool = create(
        :captain_custom_tool,
        account: account,
        slug: 'custom_fetch-order',
        title: 'Fetch Order'
      )
      create(
        :captain_scenario,
        assistant: assistant,
        account: account,
        instruction: 'Use [@Fetch Order](tool://custom_fetch-order)'
      )

      custom_tool.update!(enabled: false)

      preview = described_class.new(assistant: assistant).preview

      expect(preview.dig(:scenarios, 0, :used_tool_ids)).to eq(['handoff'])
      expect(preview.dig(:scenarios, 0, :layers)).to include(
        include(
          id: 'tool_ids',
          title: 'Runtime tool IDs',
          enabled: true,
          values: ['handoff']
        )
      )
    end
  end
end
