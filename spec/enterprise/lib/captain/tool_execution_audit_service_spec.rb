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

  it 'redacts knowledge-entry question and answer arguments in audit payloads' do
    described_class.record(
      assistant: assistant,
      scope_name: Captain::ToolAccess::SCOPE_ASSISTANT,
      tool_definition: {
        id: 'create_captain_knowledge_entry',
        title: 'Create Captain Knowledge Entry',
        risk_level: 'high',
        requires_confirmation: true
      },
      arguments: {
        assistant_id: assistant.id,
        question: 'How do I pay?',
        answer: 'Use the invoice portal.',
        status: 'approved'
      },
      result: { success: true },
      user: user
    )

    audit_payload = Enterprise::AuditLog.where(action: 'captain_tool_execute').last.audited_changes
    serialized_payload = JSON.generate(audit_payload)

    expect(audit_payload.dig('arguments', 'question')).to eq('[FILTERED]')
    expect(audit_payload.dig('arguments', 'answer')).to eq('[FILTERED]')
    expect(serialized_payload).not_to include('How do I pay?')
    expect(serialized_payload).not_to include('Use the invoice portal.')
  end

  it 'redacts knowledge document source arguments in audit payloads' do
    described_class.record(
      assistant: assistant,
      scope_name: Captain::ToolAccess::SCOPE_ASSISTANT,
      tool_definition: {
        id: 'create_captain_knowledge_document',
        title: 'Create Captain Knowledge Document',
        risk_level: 'high',
        requires_confirmation: true
      },
      arguments: {
        assistant_id: assistant.id,
        name: 'Docs',
        external_link: 'https://docs.example.test/page?token=abc',
        selected_urls_json: ['https://docs.example.test/selected?secret=1'].to_json,
        import_profile_json: { include_paths: ['/safe'] }.to_json
      },
      result: { success: true },
      user: user
    )

    audit_payload = Enterprise::AuditLog.where(action: 'captain_tool_execute').last.audited_changes
    serialized_payload = JSON.generate(audit_payload)

    expect(audit_payload.dig('arguments', 'external_link')).to eq('[FILTERED]')
    expect(audit_payload.dig('arguments', 'selected_urls_json')).to eq('[FILTERED]')
    expect(serialized_payload).not_to include('docs.example.test')
    expect(serialized_payload).not_to include('token=abc')
  end

  it 'redacts result and error text in audit payloads' do
    described_class.record(
      assistant: assistant,
      scope_name: Captain::ToolAccess::SCOPE_ASSISTANT,
      tool_definition: {
        id: 'create_captain_knowledge_document',
        title: 'Create Captain Knowledge Document',
        risk_level: 'high',
        requires_confirmation: true
      },
      arguments: { assistant_id: assistant.id },
      result: {
        success: false,
        message: 'Failed to import https://docs.example.test/page?token=abc',
        error: 'source_text contains raw content'
      },
      error: StandardError.new('artifact signed-artifact-id failed'),
      user: user
    )

    audit_payload = Enterprise::AuditLog.where(action: 'captain_tool_execute').last.audited_changes
    serialized_payload = JSON.generate(audit_payload)

    expect(audit_payload['result_message']).to eq('[FILTERED]')
    expect(audit_payload['result_error']).to eq('[FILTERED]')
    expect(audit_payload['error_message']).to eq('[FILTERED]')
    expect(serialized_payload).not_to include('docs.example.test')
    expect(serialized_payload).not_to include('signed-artifact-id')
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
