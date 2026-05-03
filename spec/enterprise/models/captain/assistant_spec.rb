require 'rails_helper'

RSpec.describe Captain::Assistant, type: :model do
  describe 'validations' do
    it { is_expected.to validate_length_of(:description).is_at_most(Captain::Assistant::DESCRIPTION_MAX_LENGTH) }

    it 'allows prompt instructions up to the product limit' do
      assistant = build(:captain_assistant, account: create(:account), description: 'a' * Captain::Assistant::DESCRIPTION_MAX_LENGTH)

      expect(assistant).to be_valid
    end

    it 'rejects prompt instructions above the product limit' do
      assistant = build(:captain_assistant, account: create(:account), description: 'a' * (Captain::Assistant::DESCRIPTION_MAX_LENGTH + 1))

      expect(assistant).not_to be_valid
      expect(assistant.errors.details[:description]).to include(error: :too_long, count: Captain::Assistant::DESCRIPTION_MAX_LENGTH)
    end

    it 'allows external assistants with names that do not transliterate into ASCII' do
      assistant = build(:captain_assistant, account: create(:account), name: 'Арманище')

      expect(assistant).to be_valid
      expect(assistant.handoff_target_name).to match(/\Aassistant_[a-f0-9]{12}\z/)
      expect(assistant.handoff_tool_name).to match(/\Ahandoff_to_assistant_[a-f0-9]{12}\z/)
    end

    it 'truncates long external assistant names to stay within the runtime limit' do
      assistant = build(
        :captain_assistant,
        account: create(:account),
        name: 'a' * (Captain::HandoffNaming::MAX_TARGET_NAME_LENGTH + 20)
      )

      expect(assistant).to be_valid
      expect(assistant.handoff_target_name.length).to be <= Captain::HandoffNaming::MAX_TARGET_NAME_LENGTH
      expect(assistant.handoff_tool_name.length).to be <= Captain::HandoffNaming::MAX_TOOL_NAME_LENGTH
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

  describe '#runtime_state_for' do
    let(:account) { create(:account) }
    let(:assistant) { create(:captain_assistant, account: account) }
    let(:conversation) { create(:conversation, account: account) }

    it 'keeps the assistant runtime-state path compatible while delegating to ContextFields' do
      state = assistant.send(:runtime_state_for, conversation)

      expect(state[:conversation]).to include(
        id: conversation.id,
        display_id: conversation.display_id,
        inbox_id: conversation.inbox_id
      )
      expect(state[:contact]).to include(id: conversation.contact_id)
      expect(state).not_to have_key(:channel_type)
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

    it 'keeps account-private tools scoped to the assistant account only' do
      own_tool = create(:captain_custom_tool, account: account, slug: 'custom_own-tool')
      create(:captain_custom_tool, account: create(:account), slug: 'custom_other-tool')

      expect(assistant.available_tool_ids).to include(own_tool.slug)
      expect(assistant.available_assistant_tool_ids).to include(own_tool.slug)
      expect(assistant.available_tool_ids).not_to include('custom_other-tool')
      expect(assistant.available_assistant_tool_ids).not_to include('custom_other-tool')
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

    it 'treats an explicit empty agent tool scope as disabled defaults instead of falling back' do
      assistant.update!(
        config: {
          'context_access' => {},
          'tool_access' => {
            'agent' => {
              'enabled' => true,
              'tool_ids' => []
            }
          }
        }
      )

      expect(assistant.allowed_agent_tool_ids).to eq([])
      expect(assistant.direct_agent_tool_ids).to eq([])
      expect(assistant.scenario_agent_tool_ids).to eq([])
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

    it 'adds explicitly referenced capability tools even when their checkbox is off' do
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

      expect(assistant).to be_valid
      expect(assistant.allowed_agent_tool_ids).to contain_exactly('faq_lookup', 'handoff')
    end

    it 'does not include non-default tools in the runtime set when they are only checked but not referenced' do
      account.enable_features!('crm_deals')

      assistant.update!(
        config: {
          'context_access' => {},
          'tool_access' => {
            'agent' => {
              'enabled' => true,
              'tool_ids' => %w[faq_lookup handoff create_deal]
            }
          }
        }
      )

      expect(assistant.allowed_agent_tool_ids).to contain_exactly('faq_lookup', 'handoff')
      expect(assistant.prompt_runtime_agent_tools.pluck(:id)).to contain_exactly('faq_lookup', 'handoff')
    end

    it 'keeps explicitly referenced custom tools in the final runtime tool set' do
      create(
        :captain_custom_tool,
        account: account,
        slug: 'custom_fetch-order',
        title: 'Fetch Order',
        description: 'Gets order details'
      )

      assistant.update!(
        description: 'Use [@Fetch Order](tool://custom_fetch-order) when the customer asks.',
        config: {
          'context_access' => {},
          'tool_access' => {
            'agent' => {
              'enabled' => true,
              'tool_ids' => ['faq_lookup']
            }
          }
        }
      )

      expect(assistant.allowed_agent_tool_ids).to contain_exactly('faq_lookup', 'custom_fetch-order')
      expect(assistant.prompt_runtime_agent_tools.pluck(:id)).to contain_exactly('faq_lookup', 'custom_fetch-order')

      tools = assistant.send(:agent_tools)
      expect(tools.map(&:class)).to include(Captain::Tools::FaqLookupTool)
      expect(tools.any?(Captain::Tools::HttpTool)).to be(true)
    end

    it 'keeps explicitly referenced non-default built-in tools in the final runtime tool set without extra runtime policy gates' do
      account.enable_features!('crm_deals')

      assistant.update!(
        description: 'Use [@Create Deal](tool://create_deal) when greeted.',
        config: {
          'context_access' => {},
          'tool_access' => {
            'agent' => {
              'enabled' => true,
              'tool_ids' => ['faq_lookup']
            }
          }
        }
      )

      expect(assistant.allowed_agent_tool_ids).to contain_exactly('faq_lookup', 'create_deal')
      expect(assistant.prompt_runtime_agent_tools.pluck(:id)).to contain_exactly('faq_lookup', 'create_deal')
      expect(assistant.send(:agent_tools).map(&:class)).to contain_exactly(Captain::Tools::FaqLookupTool, Captain::Tools::CreateDealTool)
    end

    it 'does not expose scenario-only template tool references in the root assistant prompt' do
      updated_rules = assistant.rule_entries.map do |entry|
        next entry unless entry[:id] == 'scenario_role'

        entry.merge(content: 'Use [Add Private Note](tool://add_private_note) only inside the scenario role.')
      end

      assistant.update!(config: assistant.config.merge('rules' => updated_rules))

      prompt_context = assistant.send(:prompt_context)
      glossary_tool_ids = prompt_context[:tool_glossary].flat_map do |group|
        group[:entries].map { |entry| entry[:id] }
      end

      expect(assistant.prompt_runtime_agent_tools.pluck(:id)).to contain_exactly('faq_lookup', 'handoff')
      expect(glossary_tool_ids).to contain_exactly('faq_lookup', 'handoff')
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
          id: 'stay_within_scope',
          type: 'system',
          enabled: true,
          editable: false,
          deletable: false
        )
      )
      expect(assistant.rule_entries).to include(
        include(
          id: 'assistant_system_context',
          type: 'system',
          slot: 'assistant_system_context',
          enabled: true,
          editable: false,
          deletable: false
        )
      )
      expect(assistant.rule_entries).to include(
        include(
          id: 'reply_short',
          type: 'response_guideline',
          group: 'Conversation flow',
          content: 'Reply in one short paragraph.',
          enabled: true,
          editable: true,
          deletable: true
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

    it 'preserves assistant-level custom system rules after installation-managed defaults' do
      assistant.update!(
        config: assistant.config.merge(
          'rules' => [
            {
              'id' => 'custom_system_rule',
              'type' => 'system',
              'group' => 'Strict rules',
              'content' => 'Always confirm the business unit before answering.',
              'enabled' => true
            }
          ]
        )
      )

      expect(assistant.rule_entries).to include(
        include(
          id: 'custom_system_rule',
          type: 'system',
          group: 'Strict rules',
          content: 'Always confirm the business unit before answering.',
          enabled: true
        )
      )
      expect(assistant.rule_entries.index { |entry| entry[:id] == 'custom_system_rule' }).to be >=
                                                                                             described_class.installation_system_prompt_entries.length
    end

    it 'restores canonical metadata for built-in default system rules even when stored config drifted' do
      assistant.update!(
        config: assistant.config.merge(
          'rules' => [
            {
              'id' => 'stay_within_scope',
              'type' => 'system',
              'group' => 'Strict rules',
              'content' => "Stay within your configured scope and instructions. Don't digress away from them.",
              'enabled' => true,
              'editable' => false,
              'deletable' => true
            },
            {
              'id' => 'assistant_system_context',
              'type' => 'system',
              'group' => 'Assistant structure',
              'content' => 'Corrupted slot should not survive.',
              'enabled' => true,
              'slot' => 'wrong_slot',
              'editable' => false,
              'deletable' => true
            }
          ]
        )
      )

      expect(assistant.rule_entries).to include(
        include(
          id: 'stay_within_scope',
          editable: false,
          deletable: false
        )
      )
      expect(assistant.rule_entries).to include(
        include(
          id: 'assistant_system_context',
          slot: 'assistant_system_context',
          editable: false,
          deletable: false
        )
      )
    end

    it 'drops non-system duplicates that reuse installation system prompt ids' do
      scenario_role = described_class.installation_system_prompt_entries.find do |rule|
        rule[:id].to_s == 'scenario_role'
      end

      assistant.update!(
        config: assistant.config.merge(
          'rules' => [
            {
              'id' => 'scenario_role',
              'type' => 'response_guideline',
              'group' => 'Scenario structure',
              'content' => scenario_role[:content],
              'enabled' => false
            },
            {
              'id' => 'reply_short',
              'type' => 'response_guideline',
              'group' => 'Conversation flow',
              'content' => 'Reply in one short paragraph.',
              'enabled' => true
            }
          ]
        )
      )

      scenario_role_entries = assistant.reload.rule_entries.select { |entry| entry[:id].to_s == 'scenario_role' }

      expect(scenario_role_entries.size).to eq(1)
      expect(scenario_role_entries.first[:type]).to eq('system')
      expect(assistant.rule_entries).to include(include(id: 'reply_short', type: 'response_guideline'))
      expect(assistant.response_guidelines).to eq(['Reply in one short paragraph.'])
    end

    it 'rejects malformed structured rules instead of silently dropping them' do
      assistant.config = assistant.config.merge(
        'rules' => [
          {
            'id' => 'bad_rule',
            'type' => 'guardrail',
            'group' => 'Restrictions',
            'content' => '   '
          },
          'not-a-rule'
        ]
      )

      expect(assistant).not_to be_valid
      expect(assistant.errors[:config].join).to include('invalid')
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

    it 'does not render an empty specialized scenario section when none exist' do
      rendered = assistant.agent_instructions

      expect(rendered).not_to include('# Specialized Scenarios')
      expect(rendered).not_to include('The following are the scenario agents that are available to you.')
    end

    it 'renders specialized scenario handoff routes only when scenarios exist' do
      scenario = create(
        :captain_scenario,
        assistant: assistant,
        account: account,
        title: 'Billing Escalations',
        description: 'Handle complex billing issues and escalations'
      )

      rendered = assistant.agent_instructions

      expect(rendered).to include('# Specialized Scenarios')
      expect(rendered).to include('Billing Escalations: Handle complex billing issues and escalations')
      expect(rendered).to include("`handoff_to_#{scenario.handoff_key}`")
    end

    it 'renders system rules from the structured rules config' do
      rendered = assistant.agent_instructions

      expect(rendered).to include('# System Rules')
      expect(rendered).to include('Stay within your configured scope and instructions.')
      expect(rendered).to include('Use only the fields and tools explicitly available in this prompt')
      expect(rendered).to include('Mirror the user language exactly')
    end

    it 'preserves multiline prompt rules as single markdown list items with stable section spacing' do
      config_name = described_class::GLOBAL_SYSTEM_PROMPTS_INSTALLATION_CONFIG
      system_prompts_config = InstallationConfig.find_by(name: config_name)
      previous_system_prompts = system_prompts_config&.value

      begin
        upsert_installation_config(
          config_name,
          described_class.default_installation_system_prompt_entries.map do |entry|
            next entry unless entry[:id] == 'stay_within_scope'

            entry.merge(content: "System rule line one\nSystem rule line two")
          end
        )

        assistant.update!(
          description: "Instruction line one\nInstruction line two",
          response_guidelines: ["Guideline line one\nGuideline line two"],
          guardrails: ["Guardrail line one\nGuardrail line two"]
        )

        rendered = assistant.agent_instructions

        expect(rendered).to include(
          "# System Instructions\nInstruction line one\nInstruction line two\n\n# Global System Instructions",
          "- System rule line one\n  System rule line two",
          "- Guideline line one\n  Guideline line two",
          "- Guardrail line one\n  Guardrail line two"
        )
        expect(rendered).not_to include(
          "- System rule line one\nSystem rule line two",
          "- Guideline line one\nGuideline line two",
          "- Guardrail line one\nGuardrail line two"
        )
        expect(rendered).to match(/# System Context\n.+\n\n# Your Identity/m)
        expect(rendered).not_to match(/\n{3,}/)
      ensure
        if system_prompts_config
          upsert_installation_config(config_name, previous_system_prompts)
        else
          InstallationConfig.find_by(name: config_name)&.destroy!
        end
      end
    end

    it 'uses installation-wide system prompts as the source of truth while preserving assistant toggles' do
      upsert_installation_config(
        'CAPTAIN_SYSTEM_PROMPTS',
        [
          {
            id: 'stay_within_scope',
            type: 'system',
            group: 'Strict rules',
            content: 'Follow the globally configured scope rule.',
            slot: nil
          },
          {
            id: 'admin_global_rule',
            type: 'system',
            group: 'Conversation flow',
            content: 'Always confirm the ticket priority before answering.',
            slot: nil
          }
        ]
      )

      assistant.update!(
        config: assistant.config.merge(
          'rules' => assistant.rule_entries.map do |entry|
            next entry unless entry[:id] == 'stay_within_scope'

            entry.merge(content: 'Outdated assistant-local rule', enabled: false)
          end
        )
      )

      scoped_rule = assistant.rule_entries.find { |entry| entry[:id] == 'stay_within_scope' }
      global_rule = assistant.rule_entries.find { |entry| entry[:id] == 'admin_global_rule' }
      rendered = assistant.agent_instructions

      expect(scoped_rule[:content]).to eq('Follow the globally configured scope rule.')
      expect(scoped_rule[:enabled]).to be(false)
      expect(scoped_rule[:editable]).to be(false)
      expect(scoped_rule[:deletable]).to be(false)
      expect(global_rule[:content]).to eq('Always confirm the ticket priority before answering.')
      expect(rendered).not_to include('Follow the globally configured scope rule.')
      expect(rendered).to include('Always confirm the ticket priority before answering.')
    end

    it 'renders assistant prompt structure text from default system rules' do
      rendered = assistant.agent_instructions

      expect(rendered).to include('# System Context')
      expect(rendered).to include('You are part of Captain, a multi-agent AI system')
      expect(rendered).to include('# Your Identity')
      expect(rendered).to include("You are #{assistant.name}.")
      expect(rendered).to include('Act as the main orchestrator for this conversation')
    end

    it 'renders runtime clock details when the run context provides them' do
      context_double = instance_double(
        Captain::Runtime::RunContext,
        context: {
          state: {
            runtime_clock: {
              now_utc: '2026-05-03T14:00:00Z',
              now_local: '2026-05-03T19:00:00+05:00',
              timezone: 'Asia/Almaty',
              date_local: '2026-05-03',
              time_local: '19:00:00'
            },
            reply_window: {
              channel: 'official_whatsapp',
              last_incoming_at: '2026-05-03T10:00:00Z',
              closes_at: '2026-05-04T10:00:00Z',
              open_now: true
            }
          }
        }
      )

      rendered = assistant.agent_instructions(context_double)

      expect(rendered).to include('# Current Date and Time')
      expect(rendered).to include('Current local time: 2026-05-03T19:00:00+05:00')
      expect(rendered).to include('Timezone: Asia/Almaty')
      expect(rendered).to include('# Official WhatsApp Reply Window')
      expect(rendered).to include('24-hour window closes at: 2026-05-04T10:00:00Z')
    end

    it 'prioritizes explicit context, language mirroring, and single-question flow in default rules' do
      rendered = assistant.agent_instructions

      expect(rendered).to include('If the current prompt, scenario, conversation context, or visible fields already contain the answer')
      expect(rendered).to include('Do not call FAQ or knowledge tools when explicit prompt/context facts are enough')
      expect(rendered).to include('Mirror the user language exactly')
      expect(rendered).to include('Do not ask A/B questions or bundle two alternatives')
    end

    it 'lets operators disable template-backed system sections' do
      assistant.update!(
        config: assistant.config.merge(
          'rules' => assistant.rule_entries.map do |entry|
            if entry[:id] == 'assistant_system_context'
              entry.merge(enabled: false)
            else
              entry
            end
          end
        )
      )

      rendered = assistant.agent_instructions

      expect(rendered).not_to include('# System Context')
      expect(rendered).to include('# Your Identity')
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

    it 'accepts capability tools in instructions even when their checkbox is off' do
      assistant.description = 'Use [Handoff to Human](tool://handoff) if needed.'

      expect(assistant).to be_valid
      expect(assistant.allowed_agent_tool_ids).to contain_exactly('faq_lookup', 'handoff')
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
