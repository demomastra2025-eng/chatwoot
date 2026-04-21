require 'rails_helper'

RSpec.describe Captain::Assistant, type: :model do
  describe 'validations' do
    it { is_expected.to validate_length_of(:description).is_at_most(10_000) }

    it 'requires a handoff-safe normalized name' do
      assistant = build(:captain_assistant, name: '!!!')

      expect(assistant).not_to be_valid
      expect(assistant.errors[:name]).to include('must contain letters or numbers that can be used for handoff tools')
    end

    it 'rejects names whose normalized handoff target exceeds the runtime limit' do
      assistant = build(
        :captain_assistant,
        name: 'a' * (Captain::HandoffNaming::MAX_TARGET_NAME_LENGTH + 1)
      )

      expect(assistant).not_to be_valid
      expect(assistant.errors[:name]).to include(
        "is too long for handoff tools (maximum #{Captain::HandoffNaming::MAX_TARGET_NAME_LENGTH} normalized characters)"
      )
    end

    it 'allows internal assistants to keep names that are not handoff-safe' do
      assistant = build(
        :captain_assistant,
        account: create(:account),
        usage_mode: 'internal_assistant',
        name: '!!!'
      )

      expect(assistant).to be_valid
    end

    it 'allows unrelated updates for legacy assistants with already-invalid names' do
      assistant = create(:captain_assistant)
      assistant.update_column(:name, '!!!')

      assistant.description = 'Updated without renaming the assistant.'

      expect { assistant.save! }.not_to raise_error
      expect(assistant.reload.description).to eq('Updated without renaming the assistant.')
    end

    it 'falls back to a stable internal handoff name for legacy assistants with invalid names' do
      assistant = create(:captain_assistant)
      assistant.update_column(:name, '!!!')

      expect(assistant.handoff_target_name).to eq("assistant_#{assistant.id}")
      expect(assistant.handoff_tool_name).to eq("handoff_to_assistant_#{assistant.id}")
      expect(assistant.agent.name).to eq("assistant_#{assistant.id}")
    end
  end

  describe 'tool access' do
    let(:account) { create(:account) }
    let(:assistant) { create(:captain_assistant, account: account) }

    it 'keeps the default agent runtime on faq and handoff by default' do
      expect(assistant.allowed_agent_tool_ids).to contain_exactly('faq_lookup', 'handoff')
    end

    it 'keeps the direct agent runtime on faq and handoff by default' do
      expect(assistant.direct_agent_tool_ids).to contain_exactly('faq_lookup', 'handoff')
    end

    it 'keeps scenario default runtime limited to human handoff' do
      expect(assistant.send(:scenario_default_tool_ids)).to eq(['handoff'])
      expect(assistant.scenario_agent_tool_ids).to eq(['handoff'])
    end

    it 'includes enabled custom tools in the assistant scope catalog by default' do
      custom_tool = create(:captain_custom_tool, account: account)

      expect(assistant.available_assistant_tool_ids).to include(custom_tool.slug)
      expect(assistant.allowed_assistant_tool_ids).to include(custom_tool.slug)
    end

    it 'keeps every built-in agent tool available in the assistant catalog' do
      missing_tool_ids = assistant.available_tool_ids - assistant.available_assistant_tool_ids

      expect(missing_tool_ids).to be_empty
      expect(assistant.available_assistant_tool_ids).to include('faq_lookup', 'create_deal', 'create_task', 'create_appointment', 'create_touch')
    end

    it 'builds direct agent runtime tools through the shared tool catalog' do
      allow(Captain::ToolCatalog).to receive(:build_tool).and_call_original

      assistant.send(:agent_tools)

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

    it 'keeps checked capability tools in the prompt glossary together with referenced fields' do
      assistant.update!(
        description: 'Use [Handoff to Human](tool://handoff) and greet [Email](field://contact.email).',
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
              'tool_ids' => %w[faq_lookup handoff]
            }
          }
        }
      )

      prompt_context = assistant.send(:prompt_context)

      glossary_tool_ids = prompt_context[:tool_glossary].flat_map do |group|
        group[:entries].map { |entry| entry[:id] }
      end
      glossary_field_ids = prompt_context[:context_glossary].flat_map do |group|
        group[:entries].map { |entry| entry[:id] }
      end

      expect(assistant.allowed_agent_tool_ids).to contain_exactly('faq_lookup', 'handoff')
      expect(glossary_tool_ids).to contain_exactly('faq_lookup', 'handoff')
      expect(glossary_field_ids).to include('contact.email')
    end

    it 'treats unchecked capability tool references as invalid' do
      assistant.description = 'Use [Handoff to Human](tool://handoff) when needed.'
      assistant.config = {
        'context_access' => {},
        'tool_access' => {
          'agent' => {
            'enabled' => true,
            'tool_ids' => ['faq_lookup']
          }
        }
      }

      expect(assistant).not_to be_valid
      expect(assistant.errors[:description]).to include('contains invalid tools: handoff')
    end
  end

  describe '#rule_entries' do
    let(:account) { create(:account) }
    let(:assistant) { create(:captain_assistant, account: account) }

    it 'exposes default system rules together with structured editable rules from config' do
      assistant.update!(
        config: assistant.config.merge(
          'rules' => [
            {
              'id' => 'reply_short',
              'type' => 'response_guideline',
              'group' => 'Conversation flow',
              'content' => 'Reply in one short paragraph.',
              'enabled' => true
            },
            {
              'id' => 'block_legal_advice',
              'type' => 'guardrail',
              'group' => 'Restrictions',
              'content' => 'Do not provide legal advice.',
              'enabled' => false
            }
          ]
        )
      )

      expect(assistant.rule_entries.select { |entry| entry[:type] == 'system' }).not_to be_empty
      expect(assistant.rule_entries).to include(
        include(
          id: 'reply_short',
          type: 'response_guideline',
          group: 'Conversation flow',
          content: 'Reply in one short paragraph.',
          enabled: true,
          editable: true
        )
      )
      expect(assistant.rule_entries).to include(
        include(
          id: 'block_legal_advice',
          type: 'guardrail',
          group: 'Restrictions',
          enabled: false
        )
      )
      expect(assistant.response_guidelines).to eq(['Reply in one short paragraph.'])
      expect(assistant.guardrails).to eq([])
    end

    it 'keeps compatibility when legacy array fields are cleared' do
      assistant.update!(
        response_guidelines: ['Ask one clarifying question first.'],
        guardrails: ['Do not request passwords.']
      )

      assistant.update!(response_guidelines: [])

      expect(assistant.response_guidelines).to eq([])
      expect(assistant.rule_entries.none? { |entry| entry[:type] == 'response_guideline' }).to be(true)
      expect(assistant.guardrails).to eq(['Do not request passwords.'])
    end
  end

  describe '#agent_instructions' do
    let(:account) { create(:account) }
    let(:assistant) { create(:captain_assistant, account: account) }

    before do
      upsert_installation_config('CAPTAIN_AI_AGENT_SYSTEM_PROMPT', 'Never reveal internal routing.')
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

    it 'renders system rules from the structured rules config' do
      rendered = assistant.agent_instructions

      expect(rendered).to include('# System Rules')
      expect(rendered).to include('Stay within your configured scope and instructions.')
      expect(rendered).to include('Always detect the user')
    end

    it 'renders the default runtime tools in the prompt glossary' do
      rendered = assistant.agent_instructions

      expect(rendered).to include('# Reference Glossary')
      expect(rendered).to include('FAQ Lookup (faq_lookup): Search FAQ responses using semantic similarity')
      expect(rendered).to include('Handoff to Human (handoff): Hand off the current conversation to a human team')
      expect(rendered).to include('# Human Handoff Protocol')
    end

    it 'renders referenced fields alongside the effective runtime tool glossary' do
      assistant.update!(
        description: 'Use [FAQ Lookup](tool://faq_lookup) and greet [Name](field://contact.name).',
        response_guidelines: ['Mention [Conversation ID](field://conversation.display_id) when escalation starts.']
      )

      rendered = assistant.agent_instructions

      expect(rendered).to include('# Reference Glossary')
      expect(rendered).to include('Name (contact.name)')
      expect(rendered).to include('Conversation ID (conversation.display_id)')
      expect(rendered).to include('FAQ Lookup (faq_lookup): Search FAQ responses using semantic similarity')
      expect(rendered).to include('Handoff to Human (handoff): Hand off the current conversation to a human team')
      expect(rendered).not_to include('Add Private Note (add_private_note): Add a private note to a conversation')
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
      expect(rendered).to include('Handoff to Human (handoff): Hand off the current conversation to a human team')
    end

    it 'renders tool references in instructions as readable tool mentions' do
      assistant.update!(
        description: 'Use [FAQ Lookup](tool://faq_lookup) before replying.'
      )

      rendered = assistant.agent_instructions

      expect(rendered).to include('Use `FAQ Lookup` tool before replying.')
      expect(rendered).not_to include('(tool://faq_lookup)')
    end

    it 'renders handoff guidance by default when the capability is enabled in tool access' do
      rendered = assistant.agent_instructions

      expect(rendered).to include('Handoff to Human (handoff): Hand off the current conversation to a human team')
      expect(rendered).to include('# Human Handoff Protocol')
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

    it 'rejects capability tools in instructions when their checkbox is off' do
      assistant.description = 'Use [Handoff to Human](tool://handoff) if needed.'

      expect(assistant).not_to be_valid
      expect(assistant.errors[:description]).to include('contains invalid tools: handoff')
    end

    it 'accepts capability tools in instructions when their checkbox is on' do
      assistant.config['tool_access']['agent']['tool_ids'] = %w[faq_lookup handoff]
      assistant.description = 'Use [Handoff to Human](tool://handoff) if needed.'

      expect(assistant).to be_valid
      expect(assistant.allowed_agent_tool_ids).to contain_exactly('faq_lookup', 'handoff')
    end

    it 'accepts fields in response guidelines when they are explicitly referenced' do
      assistant.response_guidelines = [
        'Mention [Email](field://contact.email) only when asked.'
      ]

      expect(assistant).to be_valid
      expect(assistant.send(:prompt_context)[:context_glossary].flat_map do |group|
        group[:entries].map do |entry|
          entry[:id]
        end
      end).to include('contact.email')
    end
  end
end
