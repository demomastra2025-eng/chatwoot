require 'rails_helper'
require 'timeout'

RSpec.describe Accounts::MergeAiUsageService do
  self.use_transactional_tests = false
  include_context 'with active AI metering'

  it 'serializes a pending acknowledged send with real contact merge and retains one paid window' do
    account = create(:account)
    source = create(:contact, account: account)
    target = create(:contact, account: account)
    conversation = create(:conversation, account: account, contact: source, inbox: create(:channel_telegram, account: account).inbox)
    create(:message, account: account, conversation: conversation, message_type: :outgoing, source_id: 'first-ack',
                     additional_attributes: { 'captain_ai_reply' => {} })
    allow(Accounts::AiUsageOutbox).to receive(:deliver).and_return(false)
    pending = create(:message, account: account, conversation: conversation, message_type: :outgoing, source_id: 'queued-ack',
                               additional_attributes: { 'captain_ai_reply' => {} })
    allow(Accounts::AiUsageOutbox).to receive(:deliver).and_call_original
    ready = Queue.new
    release = Queue.new
    holder = Thread.new do
      ActiveRecord::Base.connection_pool.with_connection do
        Contact.transaction do
          Contacts::PhoneIdentityLock.acquire!(account_id: account.id)
          ready << true
          release.pop
        end
      end
    end
    Timeout.timeout(20) { ready.pop }
    merge_pid = Queue.new
    merger = Thread.new do
      ActiveRecord::Base.connection_pool.with_connection do |connection|
        merge_pid << connection.select_value('SELECT pg_backend_pid()')
        ContactMergeAction.new(account: account, base_contact: target, mergee_contact: source).perform
      end
    end
    wait_for_advisory_wait(Timeout.timeout(20) { merge_pid.pop })
    send_pid = Queue.new
    sender = Thread.new do
      ActiveRecord::Base.connection_pool.with_connection do |connection|
        send_pid << connection.select_value('SELECT pg_backend_pid()')
        Accounts::AiUsageOutbox.deliver(pending.id)
      end
    end
    wait_for_advisory_wait(Timeout.timeout(20) { send_pid.pop })
    release << true
    [holder, merger, sender].each { |worker| Timeout.timeout(30) { worker.value } }
    expect(pending.reload).to have_attributes(source_id: 'queued-ack', ai_usage_pending: false)
    expect(conversation.reload.contact_id).to eq(target.id)
    expect(Accounts::AiUsageEvent.where(account_id: account.id).pluck(:contact_id)).to eq([target.id, target.id])
    create(:message, account: account, conversation: conversation, message_type: :outgoing, source_id: 'after-merge-ack',
                     additional_attributes: { 'captain_ai_reply' => {} })
    expect(Accounts::MonthlyAiUsageService.new(account.reload).ai_dialogs_consumed).to eq(1)
  ensure
    release << true if defined?(release) && release
    [holder, merger, sender].compact.each { |worker| worker.join(15) } if defined?(holder)
  end

  def wait_for_advisory_wait(pid)
    Timeout.timeout(20) do
      loop do
        waiting = ActiveRecord::Base.connection.select_value(
          "SELECT count(*) FROM pg_locks WHERE pid = #{Integer(pid)} AND locktype = 'advisory' AND NOT granted"
        ).to_i
        break if waiting.positive?

        sleep 0.02
      end
    end
  end
end
