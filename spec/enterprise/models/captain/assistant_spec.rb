require 'rails_helper'

RSpec.describe Captain::Assistant, type: :model do
  describe 'validations' do
    it { is_expected.to validate_length_of(:description).is_at_most(2000) }
  end

  describe 'tool access' do
    let(:account) { create(:account) }
    let(:assistant) { create(:captain_assistant, account: account) }

    it 'keeps the broader scenario tool catalog available by default' do
      expect(assistant.allowed_agent_tool_ids).to include('faq_lookup', 'handoff', 'add_private_note')
    end

    it 'keeps the direct agent runtime on faq and handoff by default' do
      expect(assistant.direct_agent_tool_ids).to contain_exactly('faq_lookup', 'handoff')
    end

    it 'includes enabled custom tools in the assistant scope catalog by default' do
      custom_tool = create(:captain_custom_tool, account: account)

      expect(assistant.available_assistant_tool_ids).to include(custom_tool.slug)
      expect(assistant.allowed_assistant_tool_ids).to include(custom_tool.slug)
    end

    it 'keeps every built-in agent tool available in the assistant catalog' do
      missing_tool_ids = assistant.available_tool_ids - assistant.available_assistant_tool_ids

      expect(missing_tool_ids).to be_empty
      expect(assistant.available_assistant_tool_ids).to include('faq_lookup', 'create_deal', 'create_task', 'create_appointment')
    end

    it 'builds direct agent runtime tools through the shared tool catalog' do
      allow(Captain::ToolCatalog).to receive(:build_tool).and_call_original

      assistant.agent_tools

      expect(Captain::ToolCatalog).to have_received(:build_tool).at_least(:once).with(
        hash_including(:id),
        assistant: assistant,
        scope_name: Captain::ToolAccess::SCOPE_AGENT
      )
    end

    it 'respects configured tool access for both scopes' do
      assistant.update!(
        config: {
          'context_access' => {},
          'tool_access' => {
            'agent' => {
              'enabled' => true,
              'tool_ids' => ['faq_lookup']
            },
            'assistant' => {
              'enabled' => true,
              'tool_ids' => ['search_documentation']
            }
          }
        }
      )

      expect(assistant.allowed_agent_tool_ids).to eq(['faq_lookup'])
      expect(assistant.direct_agent_tool_ids).to eq(['faq_lookup'])
      expect(assistant.allowed_assistant_tool_ids).to eq(['search_documentation'])
    end
  end

  describe '#agent_instructions' do
    let(:account) { create(:account) }
    let(:assistant) { create(:captain_assistant, account: account) }

    before do
      create(:installation_config, name: 'CAPTAIN_AI_AGENT_SYSTEM_PROMPT', value: 'Never reveal internal routing.')
    end

    it 'renders the unified system instruction in the assistant prompt' do
      assistant.update!(description: 'Always confirm the customer goal before answering.')

      rendered = assistant.agent_instructions

      expect(rendered).to include('# System Instructions')
      expect(rendered).to include('Always confirm the customer goal before answering.')
    end

    it 'renders the installation-wide global system prompt in the assistant prompt' do
      rendered = assistant.agent_instructions

      expect(rendered).to include('# Global System Instructions')
      expect(rendered).to include('Never reveal internal routing.')
    end

    it 'does not render a reference glossary when instructions do not reference tools or fields' do
      rendered = assistant.agent_instructions

      expect(rendered).not_to include('# Reference Glossary')
    end

    it 'renders a reference glossary only for fields and tools referenced in prompt text' do
      assistant.update!(
        description: 'Use [FAQ Lookup](tool://faq_lookup) and greet [Name](field://contact.name).',
        response_guidelines: ['Mention [Conversation ID](field://conversation.display_id) when escalation starts.']
      )

      rendered = assistant.agent_instructions

      expect(rendered).to include('# Reference Glossary')
      expect(rendered).to include('Name (contact.name)')
      expect(rendered).to include('Conversation ID (conversation.display_id)')
      expect(rendered).to include('FAQ Lookup (faq_lookup): Search FAQ responses using semantic similarity')
      expect(rendered).not_to include('Handoff to Human (handoff): Hand off the current conversation to a human team')
    end

    it 'handles array-based rules and restrictions when building the prompt glossary' do
      assistant.update!(
        description: 'Start with [Name](field://contact.name).',
        response_guidelines: ['Use [FAQ Lookup](tool://faq_lookup) before replying.'],
        guardrails: ['Never expose [Conversation ID](field://conversation.display_id) to the customer.']
      )

      rendered = assistant.agent_instructions

      expect(rendered).to include('Name (contact.name)')
      expect(rendered).to include('Conversation ID (conversation.display_id)')
      expect(rendered).to include('FAQ Lookup (faq_lookup): Search FAQ responses using semantic similarity')
    end

    it 'renders tool references in instructions as readable tool mentions' do
      assistant.update!(
        description: 'Use [FAQ Lookup](tool://faq_lookup) before replying.'
      )

      rendered = assistant.agent_instructions

      expect(rendered).to include('Use `FAQ Lookup` tool before replying.')
      expect(rendered).not_to include('(tool://faq_lookup)')
    end

    it 'renders deal and task context using explicitly passed visible fields' do
      context_double = instance_double(
        Captain::Runtime::RunContext,
        context: {
          state: {
            assistant_config: { 'context_access' => {} },
            prompt_context: {
              deal: {
                'stage_name' => 'Negotiation'
              },
              task: {
                'status_name' => 'In progress'
              },
              visible_fields: {
                deal: ['stage_name'],
                task: ['status_name']
              }
            }
          }
        }
      )

      rendered = assistant.agent_instructions(context_double)

      expect(rendered).to include('Linked Deal Context')
      expect(rendered).to include('Stage Name: Negotiation')
      expect(rendered).to include('Linked Task Context')
      expect(rendered).to include('Status Name: In progress')
    end

    it 'renders appointment context using explicitly passed visible fields' do
      context_double = instance_double(
        Captain::Runtime::RunContext,
        context: {
          state: {
            assistant_config: { 'context_access' => {} },
            prompt_context: {
              appointment: {
                'status' => 'confirmed'
              },
              visible_fields: {
                appointment: ['status']
              }
            }
          }
        }
      )

      rendered = assistant.agent_instructions(context_double)

      expect(rendered).to include('Linked Appointment Context')
      expect(rendered).to include('Status: confirmed')
    end

    it 'renders custom attribute labels together with raw keys' do
      context_double = instance_double(
        Captain::Runtime::RunContext,
        context: {
          state: {
            assistant_config: { 'context_access' => {} },
            prompt_context: {
              contact: {
                custom_attributes: {
                  'vip_level' => 'gold'
                }
              },
              contact_custom_attribute_labels: {
                'vip_level' => 'VIP Level'
              }
            }
          }
        }
      )

      rendered = assistant.agent_instructions(context_double)

      expect(rendered).to include('VIP Level (vip_level): gold')
    end
  end

  describe 'instruction and rule reference validation' do
    let(:account) { create(:account) }
    let(:assistant) { create(:captain_assistant, account: account) }

    before do
      assistant.update!(
        config: {
          'context_access' => {
            'contact' => {
              'enabled' => true,
              'field_ids' => ['contact.name']
            }
          },
          'tool_access' => {
            'agent' => {
              'enabled' => true,
              'tool_ids' => ['faq_lookup']
            }
          }
        }
      )
    end

    it 'rejects tools in instructions that are not allowed by tool access' do
      assistant.description = 'Use [Handoff to Human](tool://handoff) if needed.'

      expect(assistant).not_to be_valid
      expect(assistant.errors[:description]).to include('contains invalid tools: handoff')
    end

    it 'rejects fields in response guidelines that are not allowed by context access' do
      assistant.response_guidelines = [
        'Mention [Email](field://contact.email) only when asked.'
      ]

      expect(assistant).not_to be_valid
      expect(assistant.errors[:response_guidelines]).to include('contains invalid fields: contact.email')
    end
  end
end
