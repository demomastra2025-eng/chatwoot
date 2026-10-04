# frozen_string_literal: true

require 'rails_helper'
require 'timeout'

RSpec.describe 'voice AI contact-merge conversation locking' do
  self.use_transactional_tests = false

  after { CommittedRowsCleanup.truncate! }

  def in_thread(&block)
    Thread.new do
      ActiveRecord::Base.connection_pool.with_connection(&block)
    end
  end

  def wait_for_lock_wait(backend_pid, timeout: 10)
    Timeout.timeout(timeout) do
      loop do
        waiting = ActiveRecord::Base.connection.select_value(
          "SELECT COUNT(*) FROM pg_locks WHERE pid = #{Integer(backend_pid)} AND NOT granted"
        ).to_i
        return if waiting.positive?

        sleep 0.02
      end
    end
  end

  it 'holds every mergee conversation row before the native contact merge can reassign it' do
    account = create(:account)
    inbox = create(:inbox, account: account)
    call_contact = create(:contact, account: account)
    base_contact = create(:contact, account: account)
    mergee_contact = create(:contact, account: account)
    call_conversation = create(:conversation, account: account, inbox: inbox, contact: call_contact)
    mergee_inbox = create(:inbox, account: account)
    mergee_conversation = create(:conversation, account: account, inbox: mergee_inbox, contact: mergee_contact)
    call_session = create(
      :telephony_call_session,
      account: account,
      conversation: call_conversation,
      inbox: inbox,
      provider: 'asterisk_analog',
      external_call_ref: "contact-merge-lock-#{SecureRandom.uuid}"
    )
    service = Telephony::AiVoice::ToolDispatchService.new(
      tool_name: 'merge_contacts',
      payload: {
        account_id: account.id,
        call_ref: call_session.external_call_ref,
        arguments: { base_contact_id: base_contact.id, mergee_contact_id: mergee_contact.id }
      }
    )
    lock_acquired = Queue.new
    release_lock = Queue.new
    merge_started = Queue.new
    merge_result = Queue.new

    voice_tool = in_thread do
      service.with_captain_assistant_assignment_lock do
        lock_acquired << true
        Timeout.timeout(10) { release_lock.pop }
      end
    end
    Timeout.timeout(10) { lock_acquired.pop }

    merge = in_thread do |connection|
      merge_started << connection.select_value('SELECT pg_backend_pid()').to_i
      ContactMergeAction.new(account: account, base_contact: base_contact, mergee_contact: mergee_contact).perform
      merge_result << :merged
    end
    backend_pid = Timeout.timeout(10) { merge_started.pop }
    wait_for_lock_wait(backend_pid)

    expect(merge_result).to be_empty
    release_lock << true
    Timeout.timeout(10) { voice_tool.value }
    Timeout.timeout(10) { merge.value }

    expect(merge_result.pop).to eq(:merged)
    expect(mergee_conversation.reload.contact_id).to eq(base_contact.id)
  ensure
    release_lock << true if defined?(release_lock) && release_lock.empty?
    voice_tool&.join(10)
    merge&.join(10)
  end
end
