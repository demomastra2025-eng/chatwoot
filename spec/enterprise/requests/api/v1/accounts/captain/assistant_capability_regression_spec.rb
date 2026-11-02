require 'rails_helper'
require Rails.root.join('enterprise/lib/onelink/mcp/auth_context').to_s
require Rails.root.join('enterprise/lib/onelink/mcp/captain_tool_adapter').to_s

RSpec.describe 'Assistant capability and write contract regression', type: :request do
  let(:account) { create(:account) }
  let(:platform) { create(:super_admin).tap { |u| create(:account_user, account: account, user: u, role: :administrator) } }
  let(:admin) { create(:user, account: account, role: :administrator) }
  let(:assistant) do
    create(:captain_assistant, :legacy, account: account, usage_mode: 'internal_assistant',
                                        description: 'Plain platform instruction.', config: scope_config)
  end

  # The matrix mutates only in-memory config. SQL caching avoids repeating the
  # same account/catalog reads while retaining the actual runtime policy readers.
  around { |example| ActiveRecord::Base.cache { example.run } }

  def scope_config(enabled: true, ids: [])
    { 'tool_access' => {
      'agent' => { 'enabled' => enabled, 'tool_ids' => ids },
      'assistant' => { 'enabled' => false, 'tool_ids' => [] }
    } }
  end

  def candidate_config(plan)
    { 'version' => 1, 'scopes' => plan[:scopes].transform_values do |scope|
      {
        'enabled' => scope[:enabled], 'tool_ids' => scope[:proposed_tool_ids]
      }
    end }
  end

  def workspace_policies(record, provider:, workspace_web:, auto_complete:)
    settings = record.account_settings
    understanding = settings.section('understanding').merge('web_search' => workspace_web, 'web_page_reading' => workspace_web)
    handoff = settings.section('handoff').merge('auto_completion_enabled' => auto_complete)
    allow(settings).to receive(:section).and_call_original
    allow(settings).to receive(:section).with('understanding').and_return(understanding)
    allow(settings).to receive(:section).with('handoff').and_return(handoff)
    allow(Llm::RuntimePolicy).to receive(:web_access_enabled?).and_return(provider)
  end

  def surfaces(record, user)
    agent_ctx = Onelink::Mcp::AuthContext.from_assistant_tool(assistant: record, user: user, scope_name: 'agent')
    assistant_ctx = Onelink::Mcp::AuthContext.from_assistant_tool(assistant: record, user: user)
    [agent_ctx, assistant_ctx].each { |context| allow(context).to receive(:assistant).and_return(record) }
    {
      allowed_agent: record.allowed_agent_tool_ids.sort,
      prompt_agent: record.prompt_runtime_agent_tools.pluck(:id).sort,
      voice: record.voice_runtime_agent_tools.pluck(:id).sort,
      allowed_assistant: record.allowed_assistant_tool_ids.sort,
      mcp_agent: Onelink::Mcp::CaptainToolAdapter.new(auth_context: agent_ctx).tools.pluck(:name).sort,
      mcp_assistant: Onelink::Mcp::CaptainToolAdapter.new(auth_context: assistant_ctx).tools.pluck(:name).sort
    }
  end

  it 'activates without promoting ignored internal capability references' do
    allow(Llm::RuntimePolicy).to receive(:web_access_enabled?).and_return(true)
    allow(Captain::Tools::FirecrawlService).to receive(:configured?).and_return(true)
    assistant.update!(description: 'Use [Search](tool://web_search).')
    expect(assistant.reload.config).not_to have_key('capabilities')
    before = surfaces(assistant, platform)
    plan = Captain::ToolAccessMigrationPlan.for(assistant)
    expect(plan).to include(status: 'ready', blockers: [])
    expect(before[:allowed_agent]).to eq([])
    Captain::CapabilitiesMigrationService.new(assistant: assistant, actor: platform).activate!(expected_digest: plan[:source_digest])
    after = surfaces(assistant.reload, platform)
    expect(after).to eq(before)
  end

  it 'preserves all six actual runtime surfaces in every ready case of the 128 policy combinations', :capability_matrix do
    allow(Captain::Tools::FirecrawlService).to receive(:configured?).and_return(true)
    rows = []
    legacy_ids = []
    references = Captain::ToolAccess::CAPABILITY_CONTROLLED_AGENT_TOOL_IDS.map { |id| "[Tool](tool://#{id})" }.join(', ')
    [false, true].repeated_permutation(7) do |flags|
      external, enabled, stored, referenced, provider, workspace_web, auto_complete = flags
      configured_ids = stored ? Captain::ToolAccess::CAPABILITY_CONTROLLED_AGENT_TOOL_IDS : []
      record = create(:captain_assistant, :legacy, account: account, usage_mode: external ? 'external_agent' : 'internal_assistant',
                                                   description: referenced ? references : 'Plain instruction.',
                                                   config: scope_config(enabled: enabled, ids: configured_ids))
      workspace_policies(record, provider: provider, workspace_web: workspace_web, auto_complete: auto_complete)
      expect(record.config).not_to have_key('capabilities')
      legacy_ids << record.id
      before = surfaces(record, platform)
      original = record.attributes.deep_dup
      changes = record.changes.deep_dup
      plan = Captain::ToolAccessMigrationPlan.for(record)
      expect(record.attributes).to eq(original)
      expect(record.changes).to eq(changes)
      record.config = record.config.merge('capabilities' => candidate_config(plan))
      after = surfaces(record, platform)
      rows << { ready: plan[:status] == 'ready', changed: after != before, blockers: plan[:blockers],
                flags: flags,
                before: before, after: after }
    end
    accepted = rows.select { |row| row[:ready] }
    changed = accepted.select { |row| row[:changed] }
    persisted = Captain::Assistant.where(id: legacy_ids)
    coverage = { policy_cases: rows.pluck(:flags).uniq.size, persisted_legacy: persisted.count,
                 canonical_rows: persisted.where("config ? 'capabilities'").count }
    expect(coverage).to eq(policy_cases: 128, persisted_legacy: 128, canonical_rows: 0)
    puts "CAPABILITY_MATRIX persisted_legacy=#{coverage[:persisted_legacy]} total=#{rows.size} ready=#{accepted.size} " \
         "blocked=#{rows.size - accepted.size} changed=#{changed.size}"
    expect(accepted).not_to be_empty
    expect(changed).to be_empty
  end

  it 'denies forged request impersonation, wrong-tenant reads, and revoked verified actors' do
    other = create(:account)
    create(:account_user, user: admin, account: other, role: :administrator)
    target_path = "/api/v1/accounts/#{account.id}/captain/assistants/#{assistant.id}"
    headers = admin.create_new_auth_token
    patch target_path,
          params: { assistant: { description: 'spoof' }, captain_platform_access: true,
                    super_admin_impersonation: { 'type' => 'super_admin_impersonation', 'actor_id' => platform.id } },
          headers: headers, as: :json
    expect(response).to have_http_status(:unprocessable_content)
    expect(assistant.reload.description).not_to eq('spoof')
    get "/api/v1/accounts/#{other.id}/captain/assistants/#{assistant.id}", headers: headers, as: :json
    expect(response).to have_http_status(:not_found)
    grant = SuperAdmin::ImpersonationService.issue_grant!(actor: platform, account: account, target_user: admin)
    post '/auth/sign_in', params: { email: admin.email, sso_auth_token: grant.token }, as: :json
    impersonated = response.headers.slice('access-token', 'client', 'uid')
    get "/api/v1/accounts/#{other.id}/captain/assistants", headers: impersonated, as: :json
    expect(response).to have_http_status(:unauthorized)
    platform.update!(type: 'User')
    patch target_path, params: { assistant: { description: 'revoked' } }, headers: impersonated, as: :json
    expect(response).to have_http_status(:unauthorized)
    expect(assistant.reload.description).not_to eq('revoked')
  end

  it 'rejects clinic-owned thinking effort controls at the preferences endpoint' do
    put "/api/v1/accounts/#{account.id}/captain/preferences",
        params: { captain_runtime: { assistant_thinking_effort: 'high', copilot_thinking_effort: 'high' } },
        headers: admin.create_new_auth_token, as: :json
    expect(account.reload.captain_runtime.to_h).not_to have_key('assistant_thinking_effort')
    expect(response).to have_http_status(:unprocessable_content)
  end

  it 'rejects unsupported assistant JSON fields instead of silently accepting a no-op' do
    patch "/api/v1/accounts/#{account.id}/captain/assistants/#{assistant.id}", params: { assistant: { config: { unsupported_control: true } } },
                                                                               headers: admin.create_new_auth_token, as: :json
    expect(response).to have_http_status(:unprocessable_content)
  end
end
