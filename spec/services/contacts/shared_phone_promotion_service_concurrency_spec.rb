require 'rails_helper'
require 'timeout'

# Two workers promote the same family number at the same time (two siblings from their hints, or the MedElement job and
# the administrator button): the phone identity lock serializes them and exactly one card gets the number.
RSpec.describe Contacts::SharedPhonePromotionService do
  self.use_transactional_tests = false

  let(:account) { create(:account, limits: { non_web_inboxes: ChatwootApp.max_limit }) }
  let(:phone) { SharedPhoneHelpers::FAMILY_PHONE }
  let(:mother) { create(:contact, account: account, name: 'Mother', phone_number: '+77000000008') }
  let(:admin) { create(:user, account: account) }

  # The promotion with the capabilities switched on (they ship off, see Contacts::SharedPhoneSwitches).
  before { enable_shared_phone_switches! }
  after { cleanup_account(account) }

  def fingerprint(card, previous)
    Contacts::NumberHistoryTransferPreview.new(account: account, phone: phone, card: card, previous_holder: previous).fingerprint
  end

  def run_concurrently(*jobs)
    start = Queue.new
    threads = jobs.map do |job|
      Thread.new do
        ActiveRecord::Base.connection_pool.with_connection do
          start.pop
          job.call
        rescue StandardError => e
          e
        end
      end
    end
    jobs.size.times { start << true }
    threads.map { |thread| Timeout.timeout(30) { thread.value } }
  end

  def promoted(outcomes) = outcomes.select { |outcome| outcome.is_a?(described_class::Result) && outcome.status == :promoted }

  it 'gives the number to exactly one of two siblings promoted at once', :aggregate_failures do
    shared_phone_chat(account, mother, shared_phone_cloud_inbox(account), phone.delete('+'))
    son = shared_phone_card(account, mother)
    daughter = shared_phone_card(account, mother, code: 'daughter-1', name: 'Daughter')
    prints = [son, daughter].to_h { |card| [card.id, fingerprint(card, mother)] }

    outcomes = run_concurrently(*[son, daughter].map do |card|
      -> { described_class.new(card: Contact.find(card.id), basis: 'administrator', actor: admin, expected_fingerprint: prints[card.id]).perform }
    end)

    expect(promoted(outcomes).size).to eq(1)
    expect(outcomes.grep(described_class::Error).map(&:code)).to eq(['SHARED_PHONE_TAKEN'])
    expect(Contact.where(account_id: account.id, phone_number: phone).count).to eq(1)
    expect(ContactInbox.where(inbox_id: Inbox.where(account_id: account.id).select(:id)).distinct.count(:contact_id)).to eq(1)
  end

  it 'lets the MedElement job and the administrator button promote the same card only once', :aggregate_failures do
    _contact_inbox, conversation = shared_phone_chat(account, mother, shared_phone_cloud_inbox(account), phone.delete('+'))
    son = shared_phone_card(account, mother)
    print = fingerprint(son, mother)

    outcomes = run_concurrently(
      -> { described_class.new(card: Contact.find(son.id), basis: 'medelement').perform },
      -> { described_class.new(card: Contact.find(son.id), basis: 'administrator', actor: admin, expected_fingerprint: print).perform }
    )

    expect(promoted(outcomes).size).to eq(1)
    expect(son.reload.phone_number).to eq(phone)
    expect(conversation.reload.contact_id).to eq(son.id)
    expect(conversation.messages.activity.count).to eq(1)
  end

  def cleanup_account(record)
    return unless record.persisted?

    delete_conversations(record.id)
    delete_contacts_and_inboxes(record.id)
    delete_users(record.id)
    record.reload.destroy!
  end

  def delete_conversations(account_id)
    conversation_ids = Conversation.where(account_id: account_id).pluck(:id)
    Message.where(account_id: account_id).delete_all
    CommunicationThreadConversation.where(conversation_id: conversation_ids).delete_all
    ConversationStatusTransition.where(conversation_id: conversation_ids).delete_all
    Conversation.where(id: conversation_ids).delete_all
  end

  def delete_contacts_and_inboxes(account_id)
    ContactChannelProfile.where(account_id: account_id).delete_all
    ContactInbox.where(inbox_id: Inbox.where(account_id: account_id).select(:id)).delete_all
    CommunicationThread.where(account_id: account_id).delete_all
    Contact.where(account_id: account_id).delete_all
    Inbox.where(account_id: account_id).delete_all
    Channel::Whatsapp.where(account_id: account_id).delete_all
  end

  def delete_users(account_id)
    user_ids = AccountUser.where(account_id: account_id).pluck(:user_id)
    AccountUser.where(account_id: account_id).delete_all
    User.where(id: user_ids).delete_all
  end
end
