require 'rails_helper'

RSpec.describe Captain::Scenario, type: :model do
  describe 'associations' do
    it { is_expected.to belong_to(:assistant).class_name('Captain::Assistant') }
    it { is_expected.to belong_to(:account) }
  end

  describe 'validations' do
    it { is_expected.to validate_presence_of(:title) }
    it { is_expected.to validate_presence_of(:description) }
    it { is_expected.to validate_presence_of(:instruction) }
    it { is_expected.to validate_length_of(:description).is_at_most(2000) }
    it { is_expected.to validate_length_of(:instruction).is_at_most(20_000) }
    it { is_expected.to validate_presence_of(:assistant_id) }
    it { is_expected.to validate_presence_of(:account_id) }
  end

  describe 'scopes' do
    let(:account) { create(:account) }
    let(:assistant) { create(:captain_assistant, account: account) }

    describe '.enabled' do
      it 'returns only enabled scenarios' do
        enabled_scenario = create(:captain_scenario, assistant: assistant, account: account, enabled: true)
        disabled_scenario = create(:captain_scenario, assistant: assistant, account: account, enabled: false)

        expect(described_class.enabled.pluck(:id)).to include(enabled_scenario.id)
        expect(described_class.enabled.pluck(:id)).not_to include(disabled_scenario.id)
      end
    end
  end

  describe 'callbacks' do
    let(:account) { create(:account) }
    let(:assistant) { create(:captain_assistant, account: account) }

    describe 'before_save :resolve_tool_references' do
      it 'calls resolve_tool_references before saving' do
        scenario = build(:captain_scenario, assistant: assistant, account: account)
        expect(scenario).to receive(:resolve_tool_references)
        scenario.save
      end
    end
  end

  describe '#handoff_key' do
    let(:account) { create(:account) }
    let(:assistant) { create(:captain_assistant, account: account) }

    it 'uses id plus readable slug for persisted scenarios' do
      scenario = create(:captain_scenario, assistant: assistant, account: account,
                                           title: 'Handle complex refund requests requiring manager approval steps')

      expect(scenario.handoff_key).to start_with("scenario_#{scenario.id}_")
      expect(scenario.handoff_key).to end_with('_agent')
      expect("transfer_to_#{scenario.handoff_key}".length).to be <= 60
    end

    it 'uses a truncated slug key for unsaved scenarios' do
      scenario = build(:captain_scenario, assistant: assistant, account: account,
                                          title: 'Troubleshoot payment gateway errors for recurring subscription charges')

      expect(scenario.handoff_key).to match(/\Ascenario_draft_[a-z0-9_]+_agent\z/)
      expect("transfer_to_#{scenario.handoff_key}".length).to be <= 60
    end

    it 'stays within length budget even for large ids' do
      scenario = build(:captain_scenario, assistant: assistant, account: account,
                                          title: 'A very long scenario title used only for budget verification')
      allow(scenario).to receive(:id).and_return(1_234_567_890_123_456_789)

      expect("transfer_to_#{scenario.handoff_key}".length).to be <= 60
    end

    it 'exposes the converted independent agent as a channel peer of the assistant' do
      scenario = create(:captain_scenario, assistant: assistant, account: account)
      Captain::LegacyScenarioConversionService.new.convert!(scenario.id)
      target = Captain::Assistant.find_by!(legacy_scenario_id: scenario.id)
      peer = assistant.channel_peers.find { |entry| entry.name == target.name }
      expect(peer.handoff_target_name).to eq(target.handoff_target_name)
      expect(assistant.send(:prompt_context)).not_to have_key(:scenarios)
    end
  end

  describe '#prompt_context' do
    it 'does not expose classifier reason IDs in the primary agent prompt context' do
      account = create(:account)
      assistant = create(:captain_assistant, account: account, config: {
                           'outcome_reason_settings' => { 'handoff_reasons' => [{ 'id' => 'technical', 'label' => 'Technical support', 'active' => true }] }
                         })
      scenario = build(:captain_scenario, assistant: assistant, account: account)
      expect(scenario.prompt_context).not_to have_key(:outcome_reasons)
      expect(scenario.agent_instructions).not_to include('Technical support')
    end
  end

  describe '#resolved_agent_model' do
    it 'inherits and validates the selected assistant model' do
      account = create(:account)
      selected_model = 'openai/gpt-5.4'
      allow(Llm::Models).to receive(:valid_model_for?)
        .with(:assistant, selected_model, account: account).and_return(true)
      allow(Llm::Models).to receive(:canonical_model_name).with(selected_model).and_return(selected_model)
      assistant = create(:captain_assistant, account: account, config: { 'model' => selected_model })
      scenario = build(:captain_scenario, assistant: assistant, account: account)

      expect(scenario.resolved_agent_model).to eq(selected_model)
    end
  end

  describe '#agent_instructions' do
    let(:account) { create(:account) }
    let(:assistant) { create(:captain_assistant, account: account) }
    let(:scenario) { create(:captain_scenario, assistant: assistant, account: account) }
    let!(:peer_scenario) do
      create(
        :captain_scenario,
        assistant: assistant,
        account: account,
        title: 'Billing Escalations',
        description: 'Handle complex billing issues and escalations'
      )
    end

    before do
      upsert_installation_config('CAPTAIN_AI_AGENT_SYSTEM_PROMPT', 'Never reveal internal routing.')
    end

    it 'renders deal and task context when provided through prompt context state' do
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

      rendered = scenario.agent_instructions(context_double)

      expect(rendered).to include('Deal')
      expect(rendered).to include('Stage Name: Negotiation')
      expect(rendered).to include('Task')
      expect(rendered).to include('Status Name: In progress')
    end

    it 'renders appointment context when provided through prompt context state' do
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

      rendered = scenario.agent_instructions(context_double)

      expect(rendered).to include('Appointment')
      expect(rendered).to include('Status: confirmed')
    end

    it 'renders a single glossary section instead of a duplicated available tools block' do
      account.update!(captain_runtime: { 'agent_permissioned_tool_ids' => ['handoff'] })

      rendered = scenario.agent_instructions

      expect(rendered).to include('# Reference Glossary')
      expect(rendered).to include('Handoff to Human (handoff): Hand off the current conversation to a human team')
      expect(rendered.scan('## Available Tools').size).to eq(1)
    end

    it 'uses fields referenced in its own prompt without copying parent prompt dependencies' do
      scenario.update!(instruction: 'Ask for [Name](field://contact.name) before proceeding.')
      assistant.update!(description: 'Use [Email](field://contact.email)',
                        guardrails: ['Do not expose [Conversation ID](field://conversation.display_id).'])
      rendered = scenario.agent_instructions
      expect(rendered).to include('# Reference Glossary', 'Name (contact.name)')
      expect(rendered).not_to include('Email (contact.email)', 'Conversation ID (conversation.display_id)')
    end

    it 'renders its own instructions without the parent main prompt' do
      assistant.update!(description: 'PRIVATE PARENT MAIN PROMPT')
      scenario.update!(instruction: 'Collect reservation details for the business breakfast.')
      rendered = scenario.agent_instructions
      expect(rendered).to include('# Instructions', 'Collect reservation details for the business breakfast.')
      expect(rendered).not_to include('PRIVATE PARENT MAIN PROMPT', '# Shared Assistant Context')
    end

    it 'renders the installation-wide global system prompt in scenario prompts' do
      rendered = scenario.agent_instructions

      expect(rendered).to include('# Platform context')
      expect(rendered).to include('Never reveal internal routing.')
    end

    it 'keeps platform constraints independent of legacy rule switches' do
      rendered = scenario.agent_instructions
      expect(rendered).to include('# Platform constraints', "Use only the current account's authorized context and tools.")
      expect(rendered).not_to include('# System Rules')
    end

    it 'preserves its own authored multiline instruction without importing parent rules' do
      assistant.update!(response_guidelines: ['PARENT GUIDELINE'], guardrails: ['PARENT GUARDRAIL'])
      own = "First line\nSecond line\n\n- First item\n- Second item"
      scenario.update!(instruction: own)
      rendered = scenario.agent_instructions
      expect(rendered).to include("# Instructions\n#{own}")
      expect(rendered).not_to include('PARENT GUIDELINE', 'PARENT GUARDRAIL')
    end

    it 'uses the available peer handoff tool name from the runtime naming contract' do
      peer_scenario.update!(title: 'Sales & Support')

      rendered = scenario.agent_instructions

      expect(rendered).to include("`transfer_to_#{peer_scenario.handoff_key}`")
      expect(rendered).not_to include('`transfer_to_sales_&_support`')
    end

    it 'uses a stable peer route when a legacy title has no valid slug' do
      peer_scenario.update_column(:title, '!!!')

      rendered = scenario.agent_instructions

      expect(rendered).to include("`transfer_to_scenario_#{peer_scenario.id}_agent`")
      expect(rendered).not_to include('`transfer_to_`')
    end

    it 'renders custom attribute labels together with raw keys' do
      context_double = instance_double(
        Captain::Runtime::RunContext,
        context: {
          state: {
            assistant_config: { 'context_access' => {} },
            prompt_context: {
              deal: {
                custom_attributes: {
                  'sales_region' => 'EMEA'
                }
              },
              deal_custom_attribute_labels: {
                'sales_region' => 'Sales Region'
              }
            }
          }
        }
      )

      rendered = scenario.agent_instructions(context_double)

      expect(rendered).to include('Sales Region (sales_region): EMEA')
    end

    it 'renders human handoff guidance by default when the assistant keeps handoff enabled' do
      rendered = scenario.agent_instructions

      expect(rendered).to include('# Human handoff')
      expect(rendered).to include('`handoff`')
      expect(rendered).to include('Handoff to Human (handoff): Hand off the current conversation to a human team')
    end

    it 'renders direct sibling scenario handoff guidance' do
      rendered = scenario.agent_instructions

      expect(rendered).to include("Transfer an active task only when another agent's configured scope fits it.")
      expect(rendered).to include(peer_scenario.title)
      expect(rendered).to include("`transfer_to_#{peer_scenario.handoff_key}`")
      expect(rendered).not_to include("`transfer_to_#{scenario.handoff_key}`")
    end

    it 'uses a compact identity and its own editable instructions' do
      expect(scenario.agent_instructions).to include("You are #{scenario.title}.", '# Instructions')
      expect(scenario.agent_instructions).not_to include('Handle only the scope of this scenario.', 'shared assistant rules')
    end

    it 'does not activate an unchecked capability through its own prompt mention' do
      scenario.update!(instruction: 'Use [Cancel Response](tool://cancel_response) if needed.')
      expect(scenario.prompt_runtime_tool_ids).not_to include('cancel_response')
      expect(scenario.agent_instructions).not_to include('Cancel Response (cancel_response)')
    end
  end

  describe 'tool validation and population' do
    let(:account) { create(:account) }
    let(:assistant) { create(:captain_assistant, account: account) }

    before do
      # Mock available tools
      allow(described_class).to receive(:built_in_tool_ids).and_return(%w[
                                                                         add_contact_note add_private_note update_priority
                                                                       ])
    end

    describe 'validate_instruction_tools' do
      it 'is valid with valid tool references' do
        scenario = build(:captain_scenario,
                         assistant: assistant,
                         account: account,
                         instruction: 'Use [@Add Contact Note](tool://add_contact_note) to document')

        expect(scenario).to be_valid
      end

      it 'is invalid with invalid tool references' do
        scenario = build(:captain_scenario,
                         assistant: assistant,
                         account: account,
                         instruction: 'Use [@Invalid Tool](tool://invalid_tool) to process')

        expect(scenario).not_to be_valid
        expect(scenario.errors[:instruction]).to include('contains invalid tools: invalid_tool')
      end

      it 'is valid when the assistant default tools do not preselect the referenced tool' do
        assistant.update!(
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

        scenario = build(:captain_scenario,
                         assistant: assistant,
                         account: account,
                         instruction: 'Use [@Add Contact Note](tool://add_contact_note) to document')

        expect(scenario).to be_valid
      end

      it 'is invalid with multiple invalid tools' do
        scenario = build(:captain_scenario,
                         assistant: assistant,
                         account: account,
                         instruction: 'Use [@Invalid Tool](tool://invalid_tool) and [@Another Invalid](tool://another_invalid)')

        expect(scenario).not_to be_valid
        expect(scenario.errors[:instruction]).to include('contains invalid tools: invalid_tool, another_invalid')
      end

      it 'is valid with no tool references' do
        scenario = build(:captain_scenario,
                         assistant: assistant,
                         account: account,
                         instruction: 'Just respond politely to the customer')

        expect(scenario).to be_valid
      end

      it 'is valid with blank instruction' do
        scenario = build(:captain_scenario,
                         assistant: assistant,
                         account: account,
                         instruction: '')

        # Will be invalid due to presence validation, not tool validation
        expect(scenario).not_to be_valid
        expect(scenario.errors[:instruction]).not_to include(/contains invalid tools/)
      end

      it 'is valid with custom tool references' do
        create(:captain_custom_tool, account: account, slug: 'custom_fetch-order')
        scenario = build(:captain_scenario,
                         assistant: assistant,
                         account: account,
                         instruction: 'Use [@Fetch Order](tool://custom_fetch-order) to get order details')

        expect(scenario).to be_valid
      end

      it 'is valid with markdown-escaped custom tool references' do
        create(:captain_custom_tool, account: account, slug: 'custom_fetch_characters')
        scenario = build(:captain_scenario,
                         assistant: assistant,
                         account: account,
                         instruction: 'Use [@Fetch Characters](tool://custom\\_fetch\\_characters) to get character data')

        expect(scenario).to be_valid
      end

      it 'is invalid with custom tool from different account' do
        other_account = create(:account)
        create(:captain_custom_tool, account: other_account, slug: 'custom_fetch-order')
        scenario = build(:captain_scenario,
                         assistant: assistant,
                         account: account,
                         instruction: 'Use [@Fetch Order](tool://custom_fetch-order) to get order details')

        expect(scenario).not_to be_valid
        expect(scenario.errors[:instruction]).to include('contains invalid tools: custom_fetch-order')
      end

      it 'is invalid with disabled custom tool' do
        create(:captain_custom_tool, account: account, slug: 'custom_fetch-order', enabled: false)
        scenario = build(:captain_scenario,
                         assistant: assistant,
                         account: account,
                         instruction: 'Use [@Fetch Order](tool://custom_fetch-order) to get order details')

        expect(scenario).not_to be_valid
        expect(scenario.errors[:instruction]).to include('contains invalid tools: custom_fetch-order')
      end

      it 'is valid with mixed static and custom tool references' do
        create(:captain_custom_tool, account: account, slug: 'custom_fetch-order')
        scenario = build(:captain_scenario,
                         assistant: assistant,
                         account: account,
                         instruction: 'Use [@Cancel Response](tool://cancel_response) and [@Fetch Order](tool://custom_fetch-order)')

        expect(scenario).to be_valid
      end
    end

    describe 'resolve_tool_references' do
      it 'populates tools array with referenced tool IDs' do
        scenario = create(:captain_scenario,
                          assistant: assistant,
                          account: account,
                          instruction: 'First [@Add Contact Note](tool://add_contact_note) then [@Update Priority](tool://update_priority)')

        expect(scenario.tools).to eq(%w[add_contact_note update_priority])
      end

      it 'sets tools to nil when no tools are referenced' do
        scenario = create(:captain_scenario,
                          assistant: assistant,
                          account: account,
                          instruction: 'Just respond politely to the customer')

        expect(scenario.tools).to be_nil
      end

      it 'handles duplicate tool references' do
        scenario = create(:captain_scenario,
                          assistant: assistant,
                          account: account,
                          instruction: 'Use [@Add Contact Note](tool://add_contact_note) and [@Add Contact Note](tool://add_contact_note) again')

        expect(scenario.tools).to eq(['add_contact_note'])
      end

      it 'updates tools when instruction changes' do
        scenario = create(:captain_scenario,
                          assistant: assistant,
                          account: account,
                          instruction: 'Use [@Add Contact Note](tool://add_contact_note)')

        expect(scenario.tools).to eq(['add_contact_note'])

        scenario.update!(instruction: 'Use [@Update Priority](tool://update_priority) instead')
        expect(scenario.tools).to eq(['update_priority'])
      end
    end
  end

  describe 'custom tool integration' do
    let(:account) { create(:account) }
    let(:assistant) { create(:captain_assistant, account: account) }

    before do
      account.update!(
        captain_runtime: {
          'agent_permissioned_tool_ids' => ['add_contact_note'],
          'agent_high_risk_tools' => true
        }
      )

      allow(described_class).to receive(:built_in_tool_ids).and_return(%w[add_contact_note])
      allow(described_class).to receive(:built_in_agent_tools).and_return([
                                                                            { id: 'add_contact_note', title: 'Add Contact Note',
                                                                              description: 'Add a note' }
                                                                          ])
    end

    describe '#resolved_tools' do
      it 'includes custom tool metadata' do
        create(:captain_custom_tool, account: account, slug: 'custom_fetch-order',
                                     title: 'Fetch Order', description: 'Gets order details')
        scenario = create(:captain_scenario,
                          assistant: assistant,
                          account: account,
                          instruction: 'Use [@Fetch Order](tool://custom_fetch-order)')

        resolved = scenario.send(:resolved_tools)
        expect(resolved.map { |tool| tool[:id] }).to contain_exactly('handoff', 'custom_fetch-order')

        custom_tool = resolved.find { |tool| tool[:id] == 'custom_fetch-order' }
        expect(custom_tool[:title]).to eq('Fetch Order')
        expect(custom_tool[:description]).to eq('Gets order details')
      end

      it 'does not activate an unselected note capability while preserving custom tools' do
        create(:captain_custom_tool, account: account, slug: 'custom_fetch-order')
        scenario = create(:captain_scenario,
                          assistant: assistant,
                          account: account,
                          instruction: 'Use [@Cancel Response](tool://cancel_response) and [@Fetch Order](tool://custom_fetch-order)')

        resolved = scenario.send(:resolved_tools)
        expect(resolved.length).to eq(2)
        expect(resolved.map { |t| t[:id] }).to contain_exactly('handoff', 'custom_fetch-order')
      end

      it 'does not enable an unselected system capability through a prompt reference' do
        assistant.update!(
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

        scenario = create(
          :captain_scenario,
          assistant: assistant,
          account: account,
          instruction: 'Use [@Cancel Response](tool://cancel_response)'
        )

        resolved = scenario.send(:resolved_tools)

        # Human handoff is always available; the prompt mention adds nothing else.
        expect(resolved.map { |tool| tool[:id] }).to eq(['handoff'])
      end

      it 'excludes disabled custom tools' do
        custom_tool = create(:captain_custom_tool, account: account, slug: 'custom_fetch-order', enabled: true)
        scenario = create(:captain_scenario,
                          assistant: assistant,
                          account: account,
                          instruction: 'Use [@Fetch Order](tool://custom_fetch-order)')

        custom_tool.update!(enabled: false)

        resolved = scenario.send(:resolved_tools)
        expect(resolved.map { |tool| tool[:id] }).to eq(['handoff'])
      end

      it 'does not expose explicitly referenced tools when the assistant agent scope is disabled' do
        assistant.update!(
          config: {
            'context_access' => {},
            'tool_access' => {
              'agent' => {
                'enabled' => false,
                'tool_ids' => []
              }
            }
          }
        )

        scenario = create(
          :captain_scenario,
          assistant: assistant,
          account: account,
          instruction: 'Use [@Cancel Response](tool://cancel_response)'
        )

        # An external agent's tool scope cannot be switched off; only the always-on handoff remains.
        expect(scenario.send(:resolved_tools).map { |tool| tool[:id] }).to eq(['handoff'])
        expect(scenario.runtime_tool_ids).not_to include('cancel_response')
      end
    end

    describe '#resolve_tool_instance' do
      it 'returns HttpTool instance for custom tools' do
        create(:captain_custom_tool, account: account, slug: 'custom_fetch-order')
        scenario = create(:captain_scenario, assistant: assistant, account: account)

        tool_metadata = { id: 'custom_fetch-order', custom: true }
        tool_instance = scenario.send(:resolve_tool_instance, tool_metadata)
        expect(tool_instance).to be_a(Captain::Tools::HttpTool)
      end

      it 'returns nil for disabled custom tools' do
        create(:captain_custom_tool, account: account, slug: 'custom_fetch-order', enabled: false)
        scenario = create(:captain_scenario, assistant: assistant, account: account)

        tool_metadata = { id: 'custom_fetch-order', custom: true }
        tool_instance = scenario.send(:resolve_tool_instance, tool_metadata)
        expect(tool_instance).to be_nil
      end

      it 'returns static tool instance for non-custom tools' do
        scenario = create(:captain_scenario, assistant: assistant, account: account)
        allow(described_class).to receive(:resolve_tool_class).with('add_contact_note').and_return(
          Class.new do
            def initialize(_assistant); end
          end
        )

        tool_metadata = { id: 'add_contact_note' }
        tool_instance = scenario.send(:resolve_tool_instance, tool_metadata)
        expect(tool_instance).not_to be_nil
        expect(tool_instance).not_to be_a(Captain::Tools::HttpTool)
      end
    end

    describe '#agent_tools' do
      it 'returns array of tool instances including custom tools' do
        create(:captain_custom_tool, account: account, slug: 'custom_fetch-order')
        scenario = create(:captain_scenario,
                          assistant: assistant,
                          account: account,
                          instruction: 'Use [@Fetch Order](tool://custom_fetch-order)')

        tools = scenario.send(:agent_tools)
        expect(tools.length).to eq(2)
        expect(tools.any?(Captain::Tools::HttpTool)).to be(true)
        expect(tools.any?(Captain::Tools::HandoffTool)).to be(true)
      end

      it 'excludes disabled custom tools from execution' do
        custom_tool = create(:captain_custom_tool, account: account, slug: 'custom_fetch-order', enabled: true)
        scenario = create(:captain_scenario,
                          assistant: assistant,
                          account: account,
                          instruction: 'Use [@Fetch Order](tool://custom_fetch-order)')

        custom_tool.update!(enabled: false)

        tools = scenario.send(:agent_tools)
        expect(tools.length).to eq(1)
        expect(tools.first).to be_a(Captain::Tools::HandoffTool)
      end

      it 'keeps custom execution without activating a capability through its mention' do
        create(:captain_custom_tool, account: account, slug: 'custom_fetch-order')
        scenario = create(:captain_scenario,
                          assistant: assistant,
                          account: account,
                          instruction: 'Use [@Cancel Response](tool://cancel_response) and [@Fetch Order](tool://custom_fetch-order)')

        allow(described_class).to receive(:resolve_tool_class).with('add_contact_note').and_return(
          Class.new do
            def initialize(_assistant); end
          end
        )

        tools = scenario.send(:agent_tools)
        expect(tools.length).to eq(2)
        expect(tools.any?(Captain::Tools::HttpTool)).to be(true)
        expect(tools.any?(Captain::Tools::HandoffTool)).to be(true)
      end
    end
  end

  describe 'factory' do
    it 'creates a valid scenario with associations' do
      account = create(:account)
      assistant = create(:captain_assistant, account: account)
      scenario = build(:captain_scenario, assistant: assistant, account: account)
      expect(scenario).to be_valid
    end

    it 'creates a scenario with all required attributes' do
      scenario = create(:captain_scenario)
      expect(scenario.title).to be_present
      expect(scenario.description).to be_present
      expect(scenario.instruction).to be_present
      expect(scenario.enabled).to be true
      expect(scenario.assistant).to be_present
      expect(scenario.account).to be_present
    end
  end

  describe '#runtime_tool_ids' do
    let(:account) { create(:account) }
    let(:assistant) { create(:captain_assistant, account: account) }

    it 'returns the ids of runtime-allowed tools only' do
      custom_tool = create(:captain_custom_tool, account: account, slug: 'custom_fetch-order')
      scenario = create(
        :captain_scenario,
        assistant: assistant,
        account: account,
        instruction: 'Use [@Fetch Order](tool://custom_fetch-order)'
      )

      custom_tool.update!(enabled: false)

      expect(scenario.runtime_tool_ids).to eq(['handoff'])
    end

    it 'keeps explicitly referenced built-in tools in the scenario runtime set' do
      account.enable_features!('crm_deals')
      create(:crm_field_definition, account: account, entity_kind: 'deal')
      scenario = create(
        :captain_scenario,
        assistant: assistant,
        account: account,
        instruction: 'Use [@Create Deal](tool://create_deal)'
      )

      expected_tool_ids = %w[
        handoff create_deal list_deal_pipelines list_deal_stages get_deal search_deals list_deal_custom_fields
      ]

      expect(scenario.runtime_tool_ids).to eq(expected_tool_ids)
      expect(scenario.send(:agent_tools).map(&:name)).to match_array(expected_tool_ids)
    end
  end
end
