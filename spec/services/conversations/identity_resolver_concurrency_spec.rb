require 'rails_helper'

RSpec.describe Conversations::IdentityResolver, :aggregate_failures do
  self.use_transactional_tests = false

  let!(:account) { create(:account) }
  let!(:channel) { build(:channel_api, account: account) }
  let!(:inbox) { create(:inbox, account: account, channel: channel) }
  let!(:contact) { create(:contact, account: account) }
  let!(:contact_inbox) { create(:contact_inbox, contact: contact, inbox: inbox) }

  after do
    Conversation.where(account_id: account.id).find_each(&:destroy!)
    ContactInbox.where(inbox_id: inbox.id).delete_all
    Inbox.where(id: inbox.id).delete_all
    Channel::Api.where(id: channel.id).delete_all
    Contact.where(account_id: account.id).delete_all
    Account.where(id: account.id).delete_all
  end

  it 'serializes concurrent writers for the same Contact and Inbox identity' do
    barrier = Concurrent::CyclicBarrier.new(2)
    created_ids = Queue.new

    threads = Array.new(2) do
      Thread.new do
        ActiveRecord::Base.connection_pool.with_connection do
          resolver_contact_inbox = ContactInbox.find(contact_inbox.id)
          barrier.wait

          described_class.resolve_primary!(
            contact_inbox: resolver_contact_inbox,
            attributes: { status: :open }
          ) { |created| created_ids << created.id }.id
        end
      end
    end

    resolved_ids = threads.map(&:value)

    expect(resolved_ids.uniq.size).to eq(1)
    expect(
      Conversation.where(account_id: account.id, inbox_id: inbox.id, contact_id: contact.id, identity_key: 'primary').count
    ).to eq(1)
    expect(created_ids.size).to eq(1)
  end

  it 'serializes identity resolution behind a concurrent contact merge' do
    base_contact = create(:contact, account: account)
    create(:contact_inbox, contact: base_contact, inbox: inbox)
    merge_action = ContactMergeAction.new(account: account, base_contact: base_contact, mergee_contact: contact)
    merge_reached_conversation_update = Queue.new
    continue_merge = Queue.new

    allow(merge_action).to receive(:merge_conversations).and_wrap_original do |original|
      merge_reached_conversation_update << true
      continue_merge.pop
      original.call
    end

    merge_thread = Thread.new do
      ActiveRecord::Base.connection_pool.with_connection { merge_action.perform }
    end
    merge_reached_conversation_update.pop

    resolver_thread = Thread.new do
      ActiveRecord::Base.connection_pool.with_connection do
        described_class.resolve_primary!(
          contact_inbox: ContactInbox.find(contact_inbox.id),
          attributes: { status: :open }
        )
      end
    end

    expect(resolver_thread.join(0.1)).to be_nil
    continue_merge << true
    merge_thread.join
    resolved_conversation = resolver_thread.value

    expect(resolved_conversation.reload.contact).to eq(base_contact)
    expect(
      Conversation.where(account_id: account.id, inbox_id: inbox.id, contact_id: base_contact.id, identity_key: 'primary').count
    ).to eq(1)
    expect(Conversation.where(contact_id: contact.id)).to be_empty
  end
end
