require 'rails_helper'

RSpec.describe Accounts::PrepareAiUsageService do
  def historical_reply(account, conversation, **attributes)
    message = create(:message, account: account, conversation: conversation, message_type: :outgoing,
                               additional_attributes: { 'captain_ai_reply' => {} }, **attributes)
    message.update_columns(ai_usage_version: nil) # rubocop:disable Rails/SkipsModelValidations
    message
  end

  it 'prepares old acknowledged human/AI sends once without charging or consuming new pending replies' do
    account = create(:account, custom_attributes: { 'captain_ai_dialogs_monthly' => { '2026-10' => 12 } })
    conversation = create(:conversation, account: account, inbox: create(:channel_telegram, account: account).inbox)
    old = historical_reply(account, conversation, source_id: 'historical-ack')
    historical_reply(account, conversation)
    new_reply = create(:message, account: account, conversation: conversation, message_type: :outgoing, source_id: 'new-ack',
                                 additional_attributes: { 'captain_ai_reply' => {} })
    2.times { described_class.new(batch_size: 1).perform }
    expect(Accounts::AiUsageEvent.pluck(:event_key, :quantity)).to eq([["message:#{old.id}", 0]])
    expect(account.reload.custom_attributes['captain_ai_dialogs_monthly']).to eq('2026-10' => 12)
    rollout = Accounts::AiUsageRollout.current
    expect { rollout.activate! }.to raise_error(/writers must be drained/)
    rollout.activate!(legacy_writers_drained: true)
    2.times { Accounts::DrainAiUsageJob.perform_now }
    expect(Accounts::AiUsageEvent.find_by!(event_key: "message:#{new_reply.id}").quantity).to eq(1)
    expect(Accounts::MonthlyAiUsageService.new(account.reload).ai_dialogs_consumed).to eq(1)
  end

  it 'rolls back the batch cursor and seeds together after interruption and resumes with no duplicated charge' do
    account = create(:account)
    conversation = create(:conversation, account: account, inbox: create(:channel_telegram, account: account).inbox)
    old = historical_reply(account, conversation, source_id: 'historical-ack')
    preparation = described_class.new(batch_size: 1)
    allow(preparation).to receive(:seed_sources!).and_wrap_original do |original, ids|
      original.call(ids)
      raise ActiveRecord::StatementInvalid, 'injected batch interruption'
    end
    expect { preparation.perform }.to raise_error(ActiveRecord::StatementInvalid)
    expect(Accounts::AiUsageRollout.current.cursor).to eq(0)
    expect(Accounts::AiUsageEvent.count).to eq(0)
    described_class.new(batch_size: 1).perform
    expect(Accounts::AiUsageEvent.pluck(:event_key)).to eq(["message:#{old.id}"])
  end

  it 'does not retrocharge old messages acknowledged after their preparation cursor passed' do
    account = create(:account)
    conversation = create(:conversation, account: account, inbox: create(:channel_telegram, account: account).inbox)
    old = historical_reply(account, conversation)
    described_class.new.perform
    Accounts::AiUsageRollout.current.activate!(legacy_writers_drained: true)
    old.update!(source_id: 'late-historical-ack')
    expect(Accounts::MonthlyAiUsageService.new(account.reload).ai_dialogs_consumed).to eq(0)
    expect(Accounts::AiUsageEvent.find_by!(event_key: "message:#{old.id}").quantity).to eq(0)
  end
end
