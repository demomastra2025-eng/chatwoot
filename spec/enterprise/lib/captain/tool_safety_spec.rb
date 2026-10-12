# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Captain::ToolSafety do
  let(:account) { create(:account) }
  let(:assistant) { create(:captain_assistant, account: account) }
  let(:mcp_server) { create(:captain_mcp_server, account: account) }
  # Tools that bring third-party content into the run.
  let(:inbound_external_ids) { %w[web_search web_scrape_url search_linear_issues] }
  # Tools that deliver model-written text to a customer; the output guardrail reads only the final reply.
  let(:outbound_external_ids) { %w[create_touch send_message_to_conversation edit_message] }
  let(:expected_external_ids) { inbound_external_ids + outbound_external_ids }

  def adapter(tool_id)
    Captain::Tools::Agent::AccountToolAdapter.new(assistant, tool_id: tool_id)
  end

  def mcp_tool(tool_id)
    Captain::Tools::McpTool.new(
      assistant, mcp_server, { id: tool_id, description: 'MCP tool', mcp_tool_name: 'lookup', input_schema: { 'type' => 'object' } }
    )
  end

  describe '.external_tool?' do
    it 'treats built-in system tools as internal' do
      system_tools = [
        adapter('search_available_slots'), adapter('search_scheduling_resources'), adapter('get_contact'),
        adapter('search_deals'), adapter('search_tasks'), adapter('search_documentation'), adapter('search_conversations'),
        Captain::Tools::FaqLookupTool.new(assistant), Captain::Tools::HandoffTool.new(assistant),
        Captain::Tools::AddContactNoteTool.new(assistant), Captain::Tools::AddLabelToConversationTool.new(assistant),
        Captain::Tools::CreateAppointmentTool.new(assistant), Captain::Tools::CancelResponseTool.new(assistant)
      ]

      expect(system_tools.map { |tool| described_class.external_tool?(tool) }).to all(be(false))
    end

    it 'treats the agent hand-over, task queue and request plan as internal' do
      specialist = Struct.new(:name, :assistant_id).new('Specialist', 5)
      coordination_tools = [
        Captain::Runtime::HandoffTool.new(specialist), Captain::Runtime::TaskQueueTool.new, Captain::Runtime::PartPlanTool.new
      ]

      expect(coordination_tools.map { |tool| described_class.external_tool?(tool) }).to all(be(false))
    end

    it 'treats web search, web page reading and integrations as external' do
      expect(inbound_external_ids.map { |tool_id| described_class.external_tool?(adapter(tool_id)) }).to all(be(true))
    end

    it 'treats the tools that deliver model-written text to a customer as external' do
      outbound_tools = [
        adapter('send_message_to_conversation'), adapter('edit_message'), Captain::Tools::CreateTouchTool.new(assistant)
      ]

      expect(outbound_tools.map { |tool| described_class.external_tool?(tool) }).to all(be(true))
    end

    it 'treats a clinic-defined custom HTTP tool as external, even when its slug equals a built-in id' do
      custom_tool = create(:captain_custom_tool, account: account).tool(assistant)
      impostor = create(:captain_custom_tool, account: account).tool(assistant)
      impostor.define_singleton_method(:name) { 'get_contact' }

      expect(custom_tool).to be_a(Captain::Tools::HttpTool)
      expect(described_class.external_tool?(custom_tool)).to be(true)
      expect(described_class.external_tool?(impostor)).to be(true)
    end

    it 'treats MCP tools and skill scripts as external, even when named like a built-in tool' do
      skill_script = Captain::Tools::SkillScriptTool.new(assistant, { id: 'get_contact' })

      expect(described_class.external_tool?(mcp_tool('mcp__crm__lookup'))).to be(true)
      expect(described_class.external_tool?(mcp_tool('get_contact'))).to be(true)
      expect(described_class.external_tool?(skill_script)).to be(true)
    end

    it 'treats an unknown tool as external, whatever its name' do
      unknown_class = Class.new(Captain::Runtime::Tool) do
        def name = 'search_available_slots'
        def description = 'Unregistered tool named like a built-in one'
      end

      expect(described_class.external_tool?(unknown_class.new)).to be(true)
      expect(described_class.external_tool?(Class.new(Captain::Tools::FaqLookupTool).new(assistant))).to be(true)
      expect(described_class.external_tool?(instance_double(Captain::Runtime::Tool, name: 'faq_lookup'))).to be(true)
    end

    it 'honours a tool that declares itself external through its definition' do
      {
        { provider: 'openapi' } => 'an OpenAPI provider',
        { provider: 'mcp' } => 'an MCP provider',
        { source_type: 'custom' } => 'a custom source',
        { custom: true } => 'a custom flag',
        { external_content: true } => 'an external content flag'
      }.each_key do |declaration|
        tool = Captain::Tools::FaqLookupTool.new(assistant)
        allow(tool).to receive(:tool_definition).and_return({ id: 'faq_lookup' }.merge(declaration))

        expect(described_class.external_tool?(tool)).to be(true), "expected #{declaration} to make the tool external"
      end
    end

    it 'fails closed when the tool cannot be classified' do
      allow(Rails.logger).to receive(:warn)
      allow(Captain::ToolRegistry).to receive(:definition_for_class).and_raise(StandardError, 'registry unavailable')

      expect(described_class.external_tool?(Captain::Tools::FaqLookupTool.new(assistant))).to be(true)
      expect(Rails.logger).to have_received(:warn).with(/Treating tool as external.*registry unavailable/)
    end
  end

  describe 'the built-in tool catalog' do
    it 'flags only the tools that bring third-party content in or send model-written text to a customer as external_content' do
      flagged = Captain::ToolRegistry.definitions.select(&:external_content?).map(&:id)

      expect(flagged).to match_array(expected_external_ids)
    end

    it 'flags every agent tool that needs web access or an integration, so a new one cannot be forgotten' do
      third_party = Captain::ToolRegistry.definitions.select do |definition|
        definition.supports_scope?(Captain::ToolAccess::SCOPE_AGENT) &&
          (['Web Access', 'Integrations'].include?(definition.group_name) || definition.required_integrations.any? ||
            definition.required_runtime_flags.any? { |flag| flag.start_with?('web_') })
      end

      expect(third_party.map(&:id)).to match_array(inbound_external_ids)
    end

    it 'classifies every registered agent tool as a system tool unless it is flagged external_content' do
      definitions = Captain::ToolRegistry.definitions.select { |definition| definition.supports_scope?(Captain::ToolAccess::SCOPE_AGENT) }
      tools = definitions.to_h do |definition|
        [definition.id, Captain::ToolCatalog.build_tool(definition.to_h, assistant: assistant, scope_name: Captain::ToolAccess::SCOPE_AGENT)]
      end

      expect(tools.values).to all(be_present)
      expect(tools.select { |_tool_id, tool| described_class.external_tool?(tool) }.keys).to match_array(expected_external_ids)
    end

    it 'keeps the external_content flag out of the definition payload sent to clients' do
      expect(Captain::ToolRegistry.definition_for('web_search').to_h).not_to have_key(:external_content)
    end
  end
end
