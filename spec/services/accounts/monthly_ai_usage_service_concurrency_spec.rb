require 'rails_helper'

RSpec.describe Accounts::MonthlyAiUsageService do
  self.use_transactional_tests = false

  it 'serializes contact windows and duplicate replies from separate database connections' do
    account = create(:account)
    contact = create(:contact, account: account)
    channels = Array.new(2) { create(:conversation, account: account, contact: contact, inbox: create(:inbox, account: account)) }
    ready = Queue.new
    start = Queue.new
    now = Time.utc(2026, 10, 20, 8)
    workers = channels.map do |conversation|
      Thread.new do
        ActiveRecord::Base.connection_pool.with_connection do
          service = described_class.new(Account.find(account.id))
          ready << true
          start.pop
          21.times { |idx| service.record_ai_dialog_reply!(conversation, message_id: 2000 + idx, at: now) }
        end
      end
    end
    2.times { ready.pop }
    2.times { start << true }
    workers.each(&:value)

    expect(described_class.new(account.reload).ai_dialogs_consumed(at: now)).to eq(2)
    expect(Accounts::AiUsageEvent.count).to eq(21)
    expect(Accounts::AiDialogState.find_by!(contact_id: contact.id).state['replies_count']).to eq(1)
  end

  it 'increments a call once under simultaneous retries from separate database connections' do
    call = create(:call)
    workers = Array.new(3) do
      Thread.new do
        ActiveRecord::Base.connection_pool.with_connection do
          described_class.new(Account.find(call.account_id)).record_call_analysis!(call: call, duration_seconds: 45)
        end
      end
    end
    expect(workers.map(&:value).count(true)).to eq(1)
    expect(described_class.new(call.account.reload).call_analysis_seconds_consumed).to eq(45)
    expect(Accounts::AiUsageEvent.count).to eq(1)
  end
end
