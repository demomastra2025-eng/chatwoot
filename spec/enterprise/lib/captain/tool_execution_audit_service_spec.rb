require 'rails_helper'

RSpec.describe Captain::ToolExecutionAuditService do
  let(:account) { create(:account) }
  let(:assistant) { create(:captain_assistant, account: account) }
  let(:user) { create(:user, :administrator, account: account) }
  let(:tool_audit_count) { -> { Enterprise::AuditLog.where(action: 'captain_tool_execute').count } }

  it 'always audits confirmation-required tool calls with redacted sensitive keys' do
    expect(account).not_to be_feature_enabled(:audit_logs)

    previous_tool_audit_count = Enterprise::AuditLog.where(action: 'captain_tool_execute').count

    described_class.record(
      assistant: assistant,
      scope_name: Captain::ToolAccess::SCOPE_ASSISTANT,
      tool_definition: {
        id: 'dangerous_custom_tool',
        title: 'Dangerous Custom Tool',
        risk_level: 'high',
        requires_confirmation: true
      },
      arguments: {
        api_key: 'live-api-key',
        access_key: 'live-access-key',
        nested: { refresh_token: 'refresh-secret' }
      },
      result: { ok: true, token: 'result-token' },
      user: user
    )

    expect(Enterprise::AuditLog.where(action: 'captain_tool_execute').count).to eq(previous_tool_audit_count + 1)

    audit_payload = Enterprise::AuditLog.where(action: 'captain_tool_execute').last.audited_changes

    expect(audit_payload.dig('arguments', 'api_key')).to eq('[FILTERED]')
    expect(audit_payload.dig('arguments', 'access_key')).to eq('[FILTERED]')
    expect(audit_payload.dig('arguments', 'nested', 'refresh_token')).to eq('[FILTERED]')
    expect(audit_payload['result_preview']).not_to include('result-token')
  end

  it 'does not audit public agent or read-only assistant tool calls unless audit logs or confirmation require it' do
    expect(account).not_to be_feature_enabled(:audit_logs)

    expect do
      described_class.record(
        assistant: assistant,
        scope_name: Captain::ToolAccess::SCOPE_ASSISTANT,
        tool_definition: { id: 'get_account_health', title: 'Get Account Health', risk_level: 'low', requires_confirmation: false },
        arguments: { since: 1.hour.ago.iso8601 },
        result: { success: true, data: { status: 'healthy' } },
        user: user
      )
    end.not_to change(&tool_audit_count)

    expect do
      described_class.record(
        assistant: assistant,
        scope_name: Captain::ToolAccess::SCOPE_AGENT,
        tool_definition: { id: 'faq_lookup', title: 'FAQ Lookup', risk_level: 'low', requires_confirmation: false },
        arguments: { query: 'hours' },
        result: { success: true, data: { answer: 'ok' } },
        user: user
      )
    end.not_to change(&tool_audit_count)
  end
end
