require 'rails_helper'
require Rails.root.join('enterprise/lib/onelink/mcp/auth_context').to_s
require Rails.root.join('enterprise/lib/onelink/mcp/captain_tool_adapter').to_s

RSpec.describe Captain::CapabilitiesMigrationService do
  let(:account) { create(:account) }
  let(:actor) { create(:super_admin) }
  let(:assistant) do
    create(:captain_assistant, account: account, usage_mode: 'internal_assistant', description: 'Keep these instructions.', config: {
             'tool_access' => {
               'agent' => { 'enabled' => true, 'tool_ids' => ['add_private_note'] },
               'assistant' => { 'enabled' => true, 'tool_ids' => ['get_contact'] }
             }
           })
  end
  let(:service) { described_class.new(assistant: assistant, actor: actor) }

  def activate
    service.activate!(expected_digest: Captain::ToolAccessMigrationPlan.for(assistant)[:source_digest])
  end

  it 'activates both canonical scopes without losing grants or changing instructions, and permits exact rollback', :aggregate_failures do
    before_ids = [assistant.allowed_agent_tool_ids, assistant.allowed_assistant_tool_ids]
    source = assistant.config['tool_access'].deep_dup
    plan = Captain::ToolAccessMigrationPlan.for(assistant)
    expect(plan).to include(status: 'ready', blockers: [])

    activate

    expect(assistant.reload.description).to eq('Keep these instructions.')
    expect([assistant.allowed_agent_tool_ids, assistant.allowed_assistant_tool_ids]).to eq(before_ids)
    expect(assistant.config.dig('capabilities_migration', 'legacy_tool_access')).to eq(source)
    expect(assistant.config['tool_access']).to eq(source)
    expect(Captain::ToolAccessMigrationPlan.for(assistant)[:status]).to eq('migrated')

    service.rollback!
    expect(assistant.reload.config).not_to have_key('capabilities')
    expect([assistant.allowed_agent_tool_ids, assistant.allowed_assistant_tool_ids]).to eq(before_ids)
  end

  it 'rejects a stale plan, a clinic actor and rollback after a later platform edit' do
    plan = Captain::ToolAccessMigrationPlan.for(assistant)
    assistant.update!(description: 'Changed after inventory')
    expect { service.activate!(expected_digest: plan[:source_digest]) }
      .to raise_error(Captain::AssistantConfigContract::Violation, 'capability_migration_stale')
    clinic = create(:user, account: account, role: :administrator)
    expect { described_class.new(assistant: assistant, actor: clinic).activate!(expected_digest: 'anything') }
      .to raise_error(Captain::AssistantConfigContract::Violation, 'platform_managed_capabilities')

    activate
    assistant.update!(description: 'Later platform instruction')
    expect { service.rollback! }.to raise_error(Captain::AssistantConfigContract::Violation, 'capability_rollback_stale')
    expect(assistant.reload.config).to have_key('capabilities')
  end

  it 'never binds tools from new prompt mentions or the retained legacy source after activation' do
    activate
    config = assistant.config.deep_dup
    config['tool_access']['agent']['tool_ids'] << 'send_notification'
    assistant.update!(description: 'Use [Notify](tool://send_notification).', config: config)

    expect(assistant.allowed_agent_tool_ids).to eq(['add_private_note'])
    expect(assistant.effective_agent_tool_ids(referenced_tool_ids: ['send_notification'])).to eq(['add_private_note'])
    expect(assistant.scenario_agent_tool_ids(referenced_tool_ids: ['send_notification'])).to eq(['add_private_note'])
    expect(assistant.prompt_runtime_agent_tools.pluck(:id)).to eq(['add_private_note'])
    expect(assistant.voice_runtime_agent_tools.pluck(:id)).to eq(['add_private_note'])
  end

  it 'makes MCP catalog and direct execution use the canonical scope, retaining user permission checks' do
    activate
    admin = create(:user, account: account, role: :administrator)
    context = Onelink::Mcp::AuthContext.from_assistant_tool(assistant: assistant, user: admin)
    adapter = Onelink::Mcp::CaptainToolAdapter.new(auth_context: context)

    expect(adapter.tools.pluck(:name)).to eq(['get_contact'])
    expect(adapter.call_tool(name: 'list_captain_assistants', arguments: {})[:isError]).to be(true)
  end

  it 'keeps known dormant grants but blocks unknown grants and divergent MCP defaults' do
    dormant = create(:captain_custom_tool, account: account, enabled: false)
    config = assistant.config.deep_dup
    config['tool_access']['agent']['tool_ids'] << dormant.slug
    assistant.update!(config: config)
    plan = Captain::ToolAccessMigrationPlan.for(assistant)
    expect(plan[:scopes]['agent'][:proposed_tool_ids]).to include(dormant.slug)
    expect(plan[:scopes]['agent'][:dormant_tool_ids]).to include(dormant.slug)

    config['tool_access']['agent']['tool_ids'] << 'unknown_future_tool'
    assistant.update!(config: config)
    plan = Captain::ToolAccessMigrationPlan.for(assistant)
    expect(plan[:blockers]).to include('unknown_tool_ids')
    expect { activate }.to raise_error(Captain::AssistantConfigContract::Violation, 'capability_migration_blocked')

    assistant.update!(config: { 'tool_access' => { 'assistant' => { 'enabled' => false, 'tool_ids' => [] } } })
    expect(Captain::ToolAccessMigrationPlan.for(assistant)[:blockers]).to include('mcp_surface_difference')
  end
end
