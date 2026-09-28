require 'rails_helper'
require 'timeout'

RSpec.describe Captain::Conversation::DeliveryFenceService do # rubocop:disable RSpec/SpecFilePathFormat
  self.use_transactional_tests = false

  def cleanup_account(account)
    return unless account&.persisted?

    AutomationEvent.where(account_id: account.id).delete_all
    CommunicationThreadConversation.where(account_id: account.id).delete_all
    CommunicationThread.where(account_id: account.id).destroy_all
    account.destroy!
  end

  it 'rejects an unstamped reply even when its ID exceeds an incoming committed afterward' do
    account = create(:account)
    account.enable_features!('communication_threads')
    channel = create(:channel_widget, account: account)
    assistant = create(:captain_assistant, account: account)
    create(:captain_inbox, captain_assistant: assistant, inbox: channel.inbox)
    conversation = create(:conversation, account: account, inbox: channel.inbox, status: :pending)
    incoming_saved = Queue.new
    release_incoming = Queue.new
    outgoing_saved = Queue.new

    incoming_writer = Thread.new do
      ActiveRecord::Base.connection_pool.with_connection do
        Message.transaction do
          incoming = build(:message, account: account, conversation: Conversation.find(conversation.id),
                                     inbox: channel.inbox, sender: conversation.contact, message_type: :incoming)
          incoming.skip_runtime_events = true
          incoming.save!
          incoming_saved << incoming.id
          release_incoming.pop
        end
      end
    end
    incoming_id = Timeout.timeout(15) { incoming_saved.pop }
    outgoing_writer = Thread.new do
      ActiveRecord::Base.connection_pool.with_connection do
        legacy = build(:message, account: account, conversation: Conversation.find(conversation.id),
                                 inbox: channel.inbox, sender: assistant, message_type: :outgoing,
                                 additional_attributes: {})
        legacy.skip_runtime_events = true
        Message.transaction do
          legacy.save!
          outgoing_saved << legacy.id
        end
      end
    end
    legacy_id = Timeout.timeout(15) { outgoing_saved.pop }
    expect(incoming_id).to be < legacy_id
    # The outgoing commit is visible while the lower-id incoming is uncommitted.
    Timeout.timeout(15) { sleep(0.01) until Message.exists?(id: legacy_id) }
    expect(Message.exists?(id: incoming_id)).to be(false)
    release_incoming << true
    Timeout.timeout(15) { [incoming_writer, outgoing_writer].each(&:value) }

    legacy = Message.find(legacy_id)
    expect { described_class.new(legacy).perform { raise 'late provider send' } }.not_to raise_error
    expect(legacy.reload.additional_attributes['captain_delivery_state']).to eq('cancelled')
  ensure
    release_incoming << true if incoming_writer&.alive?
    [incoming_writer, outgoing_writer].compact.each { |worker| worker.kill if worker.alive? }
    [incoming_writer, outgoing_writer].compact.each(&:join)
    cleanup_account(account)
  end
end
