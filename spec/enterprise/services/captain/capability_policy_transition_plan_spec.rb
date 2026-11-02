require 'rails_helper'

# Historical rows must bypass today's create/update normalizers.
# rubocop:disable Rails/SkipsModelValidations

RSpec.describe Captain::CapabilityPolicyTransitionPlan do
  let(:account) { create(:account) }
  let(:actor) { create(:super_admin) }
  let(:policy) { 'preserve_ai_expand_mcp_20261102' }
  let(:assistant) do
    create(:captain_assistant, :legacy, account: account, usage_mode: 'external_agent',
                                        description: 'Private policy source marker', config: {
                                          'tool_access' => { 'assistant' => { 'enabled' => false, 'tool_ids' => [] } }
                                        })
  end
  let(:service) { Captain::CapabilitiesMigrationService.new(assistant: assistant, actor: actor) }

  def plan
    service.prepare_transition(policy: policy, expected_account_id: account.id)
  end

  def apply(manifest = plan)
    service.activate!(expected_digest: manifest.fetch(:source_digest), policy: policy, expected_account_id: account.id)
  end

  around { |example| Captain::Mcp::ToolCatalog.without_discovery { example.run } }

  before do
    allow(Captain::Mcp::ToolCatalog::DiscoveryService).to receive(:new).and_raise('No external discovery permitted')
  end

  it 'replaces MCP default-all with the preserved AI scope, including resolve_conversation, through the canonical reader', :aggregate_failures do
    before = Captain::CapabilitySurfaces.new(assistant).snapshot
    expect(before[:allowed_agent]).to include('resolve_conversation')
    expect(Captain::ToolAccessMigrationPlan.for(assistant)[:status]).to eq('blocked')
    manifest = plan
    expect(manifest).to include(status: 'ready', blockers: [], policy: policy, account_id: account.id, actor_id: actor.id)
    File.write(ENV.fetch('CAPABILITY_POLICY_PROOF_PATH'), JSON.pretty_generate(manifest)) if ENV['CAPABILITY_POLICY_PROOF_PATH']
    expect(manifest[:surface_differences].keys).to all(satisfy { |key| key.to_s.start_with?('mcp_') })
    expect(manifest[:surface_differences][:mcp_agent_catalog][:removed]).not_to be_empty
    apply(manifest)
    after = Captain::CapabilitySurfaces.new(assistant.reload).snapshot
    expect(after.except(*after.keys.grep(/^mcp_/))).to eq(before.except(*before.keys.grep(/^mcp_/)))
    expect(after[:mcp_agent_catalog]).to eq(before[:allowed_agent])
    expect(after[:mcp_agent_direct]).to eq(before[:allowed_agent])
    expect(after[:mcp_assistant_catalog]).to eq(before[:allowed_assistant])
    expect(Captain::ToolAccessMigrationPlan.for(assistant)[:blockers]).to eq([])
  end

  it 'explicitly lists MCP resolve additions without adding an Agent, prompt or voice grant' do
    assistant.update_columns(config: { 'tool_access' => {
                               'agent' => { 'enabled' => true, 'tool_ids' => ['handoff'] },
                               'assistant' => { 'enabled' => false, 'tool_ids' => [] }
                             } })
    before = Captain::CapabilitySurfaces.new(assistant.reload).snapshot
    manifest = plan
    expect(manifest[:surface_differences][:mcp_agent_catalog]).to eq(added: ['resolve_conversation'], removed: [])
    expect(manifest[:surface_differences][:mcp_agent_direct]).to eq(added: ['resolve_conversation'], removed: [])
    apply(manifest)
    after = Captain::CapabilitySurfaces.new(assistant.reload).snapshot
    %i[allowed_agent prompt_agent voice allowed_assistant].each { |surface| expect(after[surface]).to eq(before[surface]) }
  end

  it 'keeps known references from the other scope as ignored provenance, not unknown quarantine' do
    assistant_only = Captain::ToolRegistry.definitions.find { |definition| !definition.supports_scope?('agent') }
    assistant.update_columns(description: "[Tool](tool://#{assistant_only.id})")
    manifest = plan
    expect(manifest[:quarantined_tool_ids]).to eq('agent' => [], 'assistant' => [])
    expect(manifest[:scopes]['agent'][:instruction_tool_ids]).to include(assistant_only.id)
    expect(manifest[:scopes]['agent'][:proposed_tool_ids]).not_to include(assistant_only.id)
    expect(manifest[:scopes]['assistant']).to include(enabled: false, proposed_tool_ids: [])
  end

  it 'does not promote a withheld stored FAQ selection into Agent, prompt or voice' do
    assistant.update_columns(config: { 'tool_access' => { 'agent' => { 'enabled' => true, 'tool_ids' => ['faq_lookup'] },
                                                          'assistant' => { 'enabled' => false, 'tool_ids' => [] } } })
    before = Captain::CapabilitySurfaces.new(assistant.reload).snapshot
    expect(before[:allowed_agent]).not_to include('faq_lookup')
    expect(Captain::ToolAccessMigrationPlan.for(assistant)[:surface_differences][:allowed_agent][:added]).to include('faq_lookup')
    manifest = plan
    expect(manifest[:scopes]['agent'][:proposed_tool_ids]).not_to include('faq_lookup')
    apply(manifest)
    after = Captain::CapabilitySurfaces.new(assistant.reload).snapshot
    %i[allowed_agent prompt_agent voice].each { |surface| expect(after[surface]).to eq(before[surface]) }
  end

  it 'retains valid unavailable selections in their original disabled scope and audits unknown nonbinding references privately',
     :aggregate_failures do
    dormant = create(:captain_custom_tool, account: account, enabled: false)
    assistant.update_columns(config: { 'tool_access' => {
                               'agent' => { 'enabled' => true, 'tool_ids' => ['retired_unmapped_id'] },
                               'assistant' => { 'enabled' => false, 'tool_ids' => [dormant.slug, 'retired_unmapped_id'] }
                             } })
    assistant.update_columns(config: assistant.config.merge('instructions' => 'Private archived source marker'))
    source = assistant.reload.config.deep_dup
    manifest = plan
    expect(manifest[:quarantined_tool_ids]).to eq('agent' => ['retired_unmapped_id'], 'assistant' => ['retired_unmapped_id'])
    expect(manifest[:scopes]['assistant']).to include(enabled: false, proposed_tool_ids: [dormant.slug], dormant_tool_ids: [dormant.slug])
    apply(manifest)
    expect(assistant.reload.config.except('capabilities', 'capabilities_migration')).to eq(source)
    expect(assistant.config.dig('capabilities', 'scopes', 'assistant', 'tool_ids')).to eq([dormant.slug])
    expect(assistant.config.dig('capabilities', 'scopes', 'agent', 'tool_ids')).not_to include(dormant.slug, 'retired_unmapped_id')
    expect(assistant.config.dig('capabilities_migration', 'policy_transition', 'manifest_digest')).to eq(manifest[:source_digest])
    public_config = Captain::AssistantSerializer.new(assistant, user: actor).config
    expect(public_config.to_json).not_to include('capabilities_migration', 'retired_unmapped_id', 'Private policy source marker',
                                                 'Private archived source marker')
    expect(manifest.to_json).not_to include('Private policy source marker', 'legacy_tool_access', 'description')
  end

  it 'preserves dependency closure without silently expanding the AI' do
    account.enable_features!('crm_deals')
    assistant.update_columns(usage_mode: 'internal_assistant', description: '[Deal](tool://create_deal)', config: { 'tool_access' => {
                               'agent' => { 'enabled' => true, 'tool_ids' => ['create_deal'] },
                               'assistant' => { 'enabled' => false, 'tool_ids' => [] }
                             } })
    before = Captain::CapabilitySurfaces.new(assistant.reload).snapshot
    manifest = plan
    expect(manifest[:scopes]['agent'][:proposed_tool_ids]).to include(*before[:allowed_agent])
    expect(manifest[:blockers]).to eq([]), manifest[:surface_differences].inspect
    apply(manifest)
    expect(Captain::CapabilitySurfaces.new(assistant.reload).snapshot[:allowed_agent]).to eq(before[:allowed_agent])
  end

  it 'refuses unrepresentable prompt/voice behavior instead of narrowing or expanding it' do
    allow(assistant).to receive(:voice_runtime_agent_tools) do
      Captain::Capabilities.configured?(assistant.config) ? [{ id: 'faq_lookup' }] : []
    end
    manifest = plan
    expect(manifest[:blockers]).to include('ai_surface_difference')
    expect(manifest[:surface_differences][:voice]).to eq(added: ['faq_lookup'], removed: [])
    original = assistant.reload.attributes.deep_dup
    expect { apply(manifest) }.to raise_error(Captain::AssistantConfigContract::Violation, 'capability_migration_blocked')
    expect(assistant.reload.attributes).to eq(original)
  end

  it 'blocks the concrete legacy voice closure counterexample without changing the source' do
    assistant.update_columns(usage_mode: 'internal_assistant', config: { 'tool_access' => {
                               'agent' => { 'enabled' => true, 'tool_ids' => ['create_deal'] },
                               'assistant' => { 'enabled' => false, 'tool_ids' => [] }
                             } })
    manifest = plan
    expect(manifest[:blockers]).to include('ai_surface_difference')
    expect(manifest[:surface_differences][:voice][:added]).not_to be_empty
    original = assistant.reload.attributes.deep_dup
    expect { apply(manifest) }.to raise_error(Captain::AssistantConfigContract::Violation, 'capability_migration_blocked')
    expect(assistant.reload.attributes).to eq(original)
  end

  it 'refuses a generic rollback that would restore legacy broader MCP grants' do
    apply
    original = assistant.reload.attributes.deep_dup
    expect { service.rollback! }.to raise_error(Captain::AssistantConfigContract::Violation, 'capability_policy_rollback_requires_review')
    expect(assistant.reload.attributes).to eq(original)
  end

  it 'does not discover an enabled external catalog or infer its permissions' do
    create(:captain_mcp_server, account: account)
    manifest = plan
    expect(manifest[:blockers]).to include('external_catalog_unverified')
    original = assistant.reload.attributes.deep_dup
    expect { apply(manifest) }.to raise_error(Captain::AssistantConfigContract::Violation, 'capability_migration_blocked')
    expect(assistant.reload.attributes).to eq(original)
  end

  it 'leaves ordinary strict activation blocked for MCP differences' do
    strict = Captain::ToolAccessMigrationPlan.for(assistant)
    expect { service.activate!(expected_digest: strict[:source_digest]) }
      .to raise_error(Captain::AssistantConfigContract::Violation, 'capability_migration_blocked')
    expect(assistant.reload.config).not_to have_key('capabilities')
  end

  it 'rejects altered prompts, workspace policy and catalog context without mutation' do
    manifest = plan
    assistant.update!(description: 'Changed instruction')
    original = assistant.reload.attributes.deep_dup
    expect { apply(manifest) }.to raise_error(Captain::AssistantConfigContract::Violation, 'capability_migration_stale')
    expect(assistant.reload.attributes).to eq(original)
    manifest = plan
    Captain::AccountSettings.new(account).update!('handoff' => { 'auto_completion_enabled' => false })
    expect { apply(manifest) }.to raise_error(Captain::AssistantConfigContract::Violation, 'capability_migration_stale')
    manifest = plan
    create(:captain_custom_tool, account: account, enabled: false)
    expect { apply(manifest) }.to raise_error(Captain::AssistantConfigContract::Violation, 'capability_migration_stale')
    expect(assistant.reload.attributes).to eq(original)
  end

  it 'binds manifests to the current platform actor and expected account' do
    manifest = plan
    other_actor = create(:super_admin)
    other = Captain::CapabilitiesMigrationService.new(assistant: assistant, actor: other_actor)
    expect { other.activate!(expected_digest: manifest[:source_digest], policy: policy, expected_account_id: account.id) }
      .to raise_error(Captain::AssistantConfigContract::Violation, 'capability_migration_stale')
    expect { service.activate!(expected_digest: manifest[:source_digest], policy: policy, expected_account_id: create(:account).id) }
      .to raise_error(Captain::AssistantConfigContract::Violation, 'capability_migration_account_mismatch')
    clinic_actor = create(:user, account: account, role: :administrator)
    unauthorized = Captain::CapabilitiesMigrationService.new(assistant: assistant, actor: clinic_actor)
    expect { unauthorized.prepare_transition(policy: policy, expected_account_id: account.id) }
      .to raise_error(Captain::AssistantConfigContract::Violation, 'platform_managed_capabilities')
    actor.update_column(:type, 'User')
    expect { apply(manifest) }.to raise_error(Captain::AssistantConfigContract::Violation, 'platform_managed_capabilities')
    expect(assistant.reload.config).not_to have_key('capabilities')
  end

  it 'replans under Account before Assistant locks, including preparation' do
    events = []
    allow(Account).to receive(:find).and_call_original
    allow(Account).to receive(:find).with(account.id).and_return(account)
    allow(account).to(receive(:with_lock).and_wrap_original do |method, *args, &block|
      events << :account
      method.call(*args, &block)
    end)
    allow(assistant).to(receive(:with_lock).and_wrap_original do |method, *args, &block|
      events << :assistant
      method.call(*args, &block)
    end)
    manifest = plan
    expect(events).to eq(%i[account assistant])
    events.clear
    apply(manifest)
    expect(events).to eq(%i[account assistant])
  end

  it 'repeats an exact applied manifest without another write and rejects edits after activation' do
    manifest = plan
    apply(manifest)
    original = assistant.reload.attributes.deep_dup
    apply(manifest)
    expect(assistant.reload.attributes).to eq(original)
    assistant.update!(description: 'Changed after activation')
    expect { apply(manifest) }.to raise_error(Captain::AssistantConfigContract::Violation, 'capability_migration_stale')
  end

  it 'rejects unsupported policy, malformed IDs, unknown scopes, wrong-scope tools and unresolved external IDs' do
    original = assistant.attributes.deep_dup
    expect { service.prepare_transition(policy: 'force_all', expected_account_id: account.id) }
      .to raise_error(Captain::AssistantConfigContract::Violation, 'unsupported_capability_transition_policy')
    expect(assistant.reload.attributes).to eq(original)
    [{ 'agent' => { 'tool_ids' => [123] } }, { 'unknown_scope' => { 'tool_ids' => [] } },
     { 'agent' => { 'tool_ids' => ['mcp__unresolved__tool'] } }].each do |access|
      assistant.update_columns(config: { 'tool_access' => access })
      manifest = plan
      expect(manifest[:status]).to eq('blocked')
      original = assistant.reload.attributes.deep_dup
      expect { apply(manifest) }.to raise_error(Captain::AssistantConfigContract::Violation, 'capability_migration_blocked')
      expect(assistant.reload.attributes).to eq(original)
    end
    wrong_scope = Captain::ToolRegistry.definitions.find { |definition| !definition.supports_scope?('agent') }
    expect(wrong_scope).to be_present
    assistant.update_columns(config: { 'tool_access' => { 'agent' => { 'tool_ids' => [wrong_scope.id.to_s] } } })
    expect(plan[:blockers]).to include('wrong_scope_tool_ids')
  end
end

# rubocop:enable Rails/SkipsModelValidations
