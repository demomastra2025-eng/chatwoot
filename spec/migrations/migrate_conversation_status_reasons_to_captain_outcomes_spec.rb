require 'rails_helper'
require Rails.root.join('db/migrate/20260831120000_migrate_conversation_status_reasons_to_captain_outcomes')

RSpec.describe MigrateConversationStatusReasonsToCaptainOutcomes do
  it 'moves legacy workspace reasons into per-assistant outcomes and removes the legacy key' do
    account = create(:account)
    account.update_column(
      :settings,
      account.settings.merge(
        'conversation_status_reason_config' => {
          'resolved' => { 'options' => ['Customer confirmed', 'customer confirmed'], 'required' => true },
          'open' => { 'options' => ['Human requested'], 'required' => false }
        }
      )
    )
    assistant = create(:captain_assistant, account: account, config: {})

    described_class.new.up

    settings = assistant.reload.config.fetch('outcome_reason_settings')
    expect(settings.fetch('completion_reasons').pluck('label')).to contain_exactly('Customer confirmed', 'Other')
    expect(settings.fetch('handoff_reasons').pluck('label')).to contain_exactly('Human requested', 'Other')
    expect(account.reload.settings).not_to have_key('conversation_status_reason_config')
  end

  it 'disables auto completion when no completion reasons can be migrated' do
    account = create(:account)
    account.update_column(
      :settings,
      account.settings.merge(
        'conversation_status_reason_config' => {
          'resolved' => { 'options' => [], 'required' => true }
        }
      )
    )
    assistant = create(:captain_assistant, account: account, config: {})

    described_class.new.up

    expect(assistant.reload.config['auto_completion_enabled']).to be(false)
  end
end
