require 'rails_helper'
require 'timeout'

RSpec.describe Crm::Deals::AutoCreateFromChannelContactService do
  self.use_transactional_tests = false

  it 'serializes simultaneous distinct inbound events and records replay receipts for both' do
    account = create(:account)
    account.enable_features!('crm_deals')
    pipeline = create(:crm_pipeline, account: account, auto_create_deal_on_channel_contact: true)
    create(:crm_stage, account: account, pipeline: pipeline, default: true)
    contact = create(:contact, account: account)
    inbox = create(:inbox, account: account, channel: create(:channel_api, account: account))
    contact_inbox = create(:contact_inbox, contact: contact, inbox: inbox)
    conversation = create(:conversation, account: account, inbox: inbox, contact: contact, contact_inbox: contact_inbox)
    messages = create_list(:message, 2, account: account, inbox: inbox, conversation: conversation, sender: contact)
    ready = Queue.new
    release = Queue.new
    results = Queue.new
    workers = messages.map do |message|
      Thread.new do
        ActiveRecord::Base.connection_pool.with_connection do
          ready << true
          release.pop
          results << described_class.new(contact_inbox: ContactInbox.find(contact_inbox.id),
                                         conversation: Conversation.find(conversation.id), message: Message.find(message.id)).perform.map(&:id)
        end
      rescue StandardError => e
        results << e
      end
    end
    Timeout.timeout(10) do
      2.times { ready.pop }
      2.times { release << true }
      workers.each(&:join)
    end
    values = 2.times.map { results.pop }

    expect(values.grep(Exception)).to eq([])
    expect(values.flatten.length).to eq(1)
    expect(account.crm_deals.where(pipeline: pipeline).count).to eq(1)
    expect(account.crm_events.where(event_type: 'channel_contact_checked').count).to eq(2)
    account.crm_deals.first.update!(closed_at: Time.current)
    messages.each do |message|
      expect(described_class.new(contact_inbox: contact_inbox, conversation: conversation, message: message).perform).to eq([])
    end
    expect(account.crm_deals.count).to eq(1)
  ensure
    workers&.each { |worker| release << true if worker.alive? }
    workers&.each { |worker| worker.join(10) }
    cleanup_test_account(account) if account&.persisted?
  end

  def cleanup_test_account(account)
    Crm::Event.where(account_id: account.id).delete_all
    Crm::StageVisit.where(account_id: account.id).delete_all
    Crm::DealContact.where(account_id: account.id).delete_all
    Crm::Deal.where(account_id: account.id).delete_all
    Crm::StageFieldRequirement.where(account_id: account.id).delete_all
    Crm::Stage.where(account_id: account.id).delete_all
    Crm::Pipeline.where(account_id: account.id).delete_all
    # Account destroys seeded CRM metadata asynchronously; this nontransactional spec must remove it synchronously.
    Crm::FieldDefinition.where(account_id: account.id).delete_all
    Crm::TaskOutcome.where(account_id: account.id).delete_all
    Crm::TaskType.where(account_id: account.id).delete_all
    Crm::TaskStatus.where(account_id: account.id).delete_all
    Message.where(account_id: account.id).delete_all
    Conversation.where(account_id: account.id).delete_all
    ContactInbox.where(inbox_id: account.inboxes.select(:id)).delete_all
    Contact.where(account_id: account.id).delete_all
    account.inboxes.destroy_all
    account.destroy!
  end
end
