require 'rails_helper'
require Rails.root.join('db/migrate/20261102013000_create_account_ai_usage_events')

RSpec.describe CreateAccountAiUsageEvents do
  it 'seeds historical acknowledged AI source ids without touching counters and excludes unsent messages' do
    account = create(:account, custom_attributes: { 'captain_ai_dialogs_monthly' => { '2026-10' => 12 } })
    inbox = create(:channel_telegram, account: account).inbox
    conversation = create(:conversation, account: account, inbox: inbox)
    messages = create_list(:message, 2, account: account, conversation: conversation, inbox: inbox, message_type: :outgoing,
                                        additional_attributes: { 'captain_ai_reply' => {} })
    messages.first.update_columns(source_id: 'historical-ack') # rubocop:disable Rails/SkipsModelValidations
    2.times { described_class.new.send(:preserve_historical_sources) }
    expect(Accounts::AiUsageEvent.where(account_id: account.id).pluck(:event_key, :quantity)).to eq([["message:#{messages.first.id}", 0]])
    expect(account.reload.custom_attributes['captain_ai_dialogs_monthly']).to eq('2026-10' => 12)
    messages.first.update!(status: :read)
    expect(account.reload.custom_attributes['captain_ai_dialogs_monthly']).to eq('2026-10' => 12)
  end
end
