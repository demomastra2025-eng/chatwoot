# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Captain::Assistant::PromptPreviewService do
  let(:account) { create(:account) }
  let(:assistant) { create(:captain_assistant, account: account, description: 'Handle billing questions only.') }

  describe '#preview' do
    it 'strictly compiles main, copilot and routed prompts with field and tool glossaries' do
      assistant.update!(description: 'Use [Name](field://contact.name).')
      target = create(:captain_assistant, account: account, description: 'Use [Email](field://contact.email).')
      assistant.update!(handoff_agent_ids: [target.id])

      preview = described_class.new(assistant: assistant).preview

      expect(preview.dig(:assistant, :compiled_prompt)).to include('# Reference Glossary', 'Name (contact.name)', 'FAQ Lookup (faq_lookup)')
      expect(preview.dig(:copilot, :compiled_prompt)).to include(assistant.system_instruction)
      expect(preview.dig(:scenarios, 0, :compiled_prompt)).to include('# Reference Glossary', 'Email (contact.email)', 'Handoff to Human (handoff)')
      expect(preview.dig(:assistant, :compiled_prompt)).not_to include('Use the glossary below to understand the exact fields and tools')
    end

    it 'builds main prompt and compiled platform previews without separate rule layers' do
      preview = described_class.new(assistant: assistant).preview
      expect(preview.dig(:assistant, :layers)).to include(
        include(id: 'instruction', title: 'System instruction', enabled: true, value: 'Handle billing questions only.')
      )
      expect(preview.dig(:assistant, :layers).pluck(:id)).not_to include('system_prompt_structure', 'system_rules', 'response_guidelines', 'guardrails')
      expect(preview.dig(:assistant, :used_tool_ids)).to contain_exactly('faq_lookup', 'handoff', 'resolve_conversation')
      expect(preview.dig(:assistant, :compiled_prompt)).to include('FAQ Lookup (faq_lookup)', 'Handoff to Human (handoff)', '# Platform constraints')
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

      expect(preview.dig(:assistant, :used_tool_ids)).to eq(%w[faq_lookup handoff resolve_conversation])
      expect(preview.dig(:assistant, :used_field_ids)).to contain_exactly(
        'contact.name',
        'conversation.display_id'
      )
    end

    it 'includes explicitly referenced custom tools in the assistant preview metadata' do
      create(
        :captain_custom_tool,
        account: account,
        slug: 'custom_fetch-order',
        title: 'Fetch Order',
        description: 'Gets order details'
      )

      assistant.update!(description: 'Use [@Fetch Order](tool://custom_fetch-order) when asked.')

      preview = described_class.new(assistant: assistant).preview

      expect(preview.dig(:assistant, :used_tool_ids)).to contain_exactly('faq_lookup', 'handoff', 'custom_fetch-order')
      expect(preview.dig(:assistant, :layers)).to include(
        include(
          id: 'available_runtime_tools',
          enabled: true,
          values: include('custom_fetch-order: Gets order details')
        )
      )
    end

    it 'shows the routed agent own prompt without importing its tools or instructions into the entry agent' do
      custom = create(:captain_custom_tool, account: account, slug: 'custom_peer_only', title: 'Peer tool')
      target = create(:captain_assistant, account: account, description: "Own peer prompt: [Peer tool](tool://#{custom.slug})")
      assistant.update!(handoff_agent_ids: [target.id])
      preview = described_class.new(assistant: assistant).preview
      expect(preview.dig(:assistant, :used_tool_ids)).to contain_exactly('faq_lookup', 'handoff', 'resolve_conversation')
      expect(preview.dig(:assistant, :compiled_prompt)).not_to include('Own peer prompt', custom.slug)
      expect(preview.dig(:scenarios, 0, :id)).to eq(target.id)
      expect(preview.dig(:scenarios, 0, :compiled_prompt)).to include('Own peer prompt', custom.slug)
      expect(preview.dig(:scenarios, 0, :compiled_prompt)).not_to include('Handle billing questions only.')
      expect(preview.dig(:scenarios, 0, :used_tool_ids)).to contain_exactly('faq_lookup', 'handoff', 'resolve_conversation', custom.slug)
    end

    it 'includes handoff in the assistant preview when the default capability is enabled' do
      preview = described_class.new(assistant: assistant).preview

      expect(preview.dig(:assistant, :used_tool_ids)).to contain_exactly('faq_lookup', 'handoff', 'resolve_conversation')
      expect(preview.dig(:assistant, :compiled_prompt)).to include('Handoff to Human (handoff)')
    end

    it 'reports only runtime-available scenario tools in preview metadata' do
      custom_tool = create(
        :captain_custom_tool,
        account: account,
        slug: 'custom_fetch-order',
        title: 'Fetch Order'
      )
      target = create(:captain_assistant, account: account, description: 'Use [@Fetch Order](tool://custom_fetch-order)')
      assistant.update!(handoff_agent_ids: [target.id])

      custom_tool.update!(enabled: false)

      preview = described_class.new(assistant: assistant).preview

      expect(preview.dig(:scenarios, 0, :used_tool_ids)).to eq(%w[faq_lookup handoff resolve_conversation])
      expect(preview.dig(:scenarios, 0, :layers)).to include(
        include(
          id: 'tool_ids',
          title: 'Runtime tool IDs',
          enabled: true,
          values: %w[faq_lookup handoff resolve_conversation]
        )
      )
    end
  end
end
