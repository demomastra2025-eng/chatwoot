require 'rails_helper'

RSpec.describe Captain::CapabilitiesMigrationService do
  let(:account) { create(:account) }
  let(:actor) { create(:super_admin) }
  let(:assistant) do
    create(:captain_assistant, :legacy, account: account, usage_mode: 'internal_assistant', config: {
             'tool_access' => { 'agent' => { 'enabled' => false, 'tool_ids' => [] },
                                'assistant' => { 'enabled' => false, 'tool_ids' => [] } }
           })
  end
  let(:service) { described_class.new(assistant: assistant, actor: actor) }
  let(:policy) { 'preserve_ai_expand_mcp_20261102' }

  around { |example| Captain::Mcp::ToolCatalog.without_discovery { example.run } }

  def expect_invalid_profile(field)
    original = assistant.reload.attributes.deep_dup
    manifest = service.prepare_transition(policy: policy, expected_account_id: account.id)
    expect(manifest[:blockers]).to include('invalid_assistant_metadata')
    expect(manifest[:invalid_fields]).to include(field)
    expect do
      service.activate!(expected_digest: manifest[:source_digest], policy: policy, expected_account_id: account.id)
    end.to raise_error(Captain::AssistantConfigContract::Violation, 'capability_migration_blocked')
    expect(assistant.reload.attributes).to eq(original)
  end

  it 'blocks blank historical required metadata without changing the source' do
    assistant.update_column(:name, '') # rubocop:disable Rails/SkipsModelValidations
    expect_invalid_profile('name')
  end

  it 'blocks a historical internal assistant connected to an inbox' do
    inbox = create(:inbox, account: account)
    channel = create(:captain_inbox, inbox: inbox)
    channel.update_column(:captain_assistant_id, assistant.id) # rubocop:disable Rails/SkipsModelValidations
    expect_invalid_profile('usage_mode')
  end

  it 'retains follow-up validation and exposes only field names' do
    assistant.update_column(:config, assistant.config.merge('follow_up_settings' => { 'steps' => 'invalid' })) # rubocop:disable Rails/SkipsModelValidations
    expect_invalid_profile('config')
  end
end
