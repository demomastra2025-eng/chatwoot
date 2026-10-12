require 'rails_helper'

# Production holds an agent whose stored tool_access is an array of pairs.
# Reading it must behave like "not configured" everywhere instead of raising.
RSpec.describe Captain::ToolAccess do
  let(:account) { create(:account) }
  let(:assistant) { create(:captain_assistant, account: account) }
  let(:legacy_config) { { 'tool_access' => [['faq_lookup', true]], 'feature_faq' => true } }

  before { assistant.update_column(:config, legacy_config) }

  it 'treats a non-Hash tool_access as unconfigured' do
    expect(described_class.raw_scope(assistant.reload.config, 'agent')).to be_nil
    expect(described_class.raw_scope({ 'tool_access' => { 'agent' => 'on' } }, 'agent')).to be_nil
    expect(described_class.raw_scope({ 'tool_access' => { 'agent' => { 'enabled' => true } } }, :agent)).to eq('enabled' => true)
  end

  it 'resolves tools and web permissions without raising' do
    assistant.reload

    expect { described_class.normalized_access_for(assistant) }.not_to raise_error
    expect do
      described_class.allowed_tool_ids_for(assistant, Captain::ToolAccess::SCOPE_AGENT, fallback_ids: ['faq_lookup'])
    end.not_to raise_error
    expect { described_class.per_assistant_web_tool_enabled?(assistant, 'web_search') }.not_to raise_error
  end

  it 'lets the account settings backfill and snapshot read the agent' do
    expect { Captain::AccountSettings.from_assistant(assistant.reload) }.not_to raise_error
    expect { Captain::AccountSettingsBackfill.backfill!(account) }.not_to raise_error
    expect(Captain::AccountSettings.new(account.reload).section('faq')['generate_from_resolved']).to be(true)
  end

  it 'still saves the agent' do
    assistant.reload.name = 'Renamed'

    expect { assistant.save! }.not_to raise_error
  end
end
