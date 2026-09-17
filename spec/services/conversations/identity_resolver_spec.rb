require 'rails_helper'

RSpec.describe Conversations::IdentityResolver do
  let(:account) { create(:account) }
  let(:channel) { create(:channel_sms, account: account) }
  let(:inbox) { create(:inbox, account: account, channel: channel) }
  let(:contact) { create(:contact, account: account) }
  let(:contact_inbox) { create(:contact_inbox, contact: contact, inbox: inbox) }
  let(:attributes) { { status: :open, additional_attributes: { 'source' => 'identity-spec' } } }

  describe '.resolve_primary!' do
    it 'creates one primary conversation with canonical tenant links' do
      foreign_account = create(:account)

      conversation = described_class.resolve_primary!(
        contact_inbox: contact_inbox,
        attributes: attributes.merge(account_id: foreign_account.id, contact_id: create(:contact, account: foreign_account).id)
      )

      expect(conversation).to have_attributes(
        account_id: account.id,
        inbox_id: inbox.id,
        contact_id: contact.id,
        contact_inbox_id: contact_inbox.id,
        identity_key: described_class::PRIMARY_KEY
      )
    end

    it 'returns an existing primary conversation without running create-once side effects' do
      existing = create(:conversation, account: account, inbox: inbox, contact: contact, contact_inbox: contact_inbox,
                                       identity_key: described_class::PRIMARY_KEY)
      side_effect_runs = 0

      conversation = described_class.resolve_primary!(contact_inbox: contact_inbox, attributes: attributes) do
        side_effect_runs += 1
      end

      expect(conversation).to eq(existing)
      expect(side_effect_runs).to eq(0)
      expect(contact_inbox.conversations.count).to eq(1)
    end

    it 'claims the latest legacy conversation instead of creating another record' do
      create(:conversation, account: account, inbox: inbox, contact: contact, contact_inbox: contact_inbox,
                            created_at: 2.days.ago, last_activity_at: 2.days.ago, status: :open)
      latest = create(:conversation, account: account, inbox: inbox, contact: contact, contact_inbox: contact_inbox,
                                     created_at: 1.day.ago, last_activity_at: 1.day.ago, status: :resolved)
      side_effect_runs = 0

      conversation = described_class.resolve_primary!(contact_inbox: contact_inbox, attributes: attributes) do
        side_effect_runs += 1
      end

      expect(conversation).to eq(latest)
      expect(conversation.reload.identity_key).to eq(described_class::PRIMARY_KEY)
      expect(side_effect_runs).to eq(0)
      expect(contact_inbox.conversations.count).to eq(2)
    end

    it 'reuses the canonical conversation across source identities for the same contact and inbox' do
      previous_contact_inbox = create(:contact_inbox, contact: contact, inbox: inbox, source_id: 'previous-source')
      existing = create(
        :conversation,
        account: account,
        inbox: inbox,
        contact: contact,
        contact_inbox: previous_contact_inbox,
        additional_attributes: { 'chat_id' => 'previous-source', 'preserved' => true }
      )
      current_attributes = attributes.merge(additional_attributes: { 'chat_id' => 'current-source' })

      conversation = described_class.resolve_primary!(contact_inbox: contact_inbox, attributes: current_attributes)

      expect(conversation).to eq(existing)
      expect(conversation.reload.identity_key).to eq(described_class::PRIMARY_KEY)
      expect(conversation.contact_inbox).to eq(contact_inbox)
      expect(conversation.additional_attributes).to include('chat_id' => 'current-source', 'preserved' => true)
      expect(Conversation.where(account_id: account.id, inbox_id: inbox.id, contact_id: contact.id).count).to eq(1)
    end

    it 'runs create-once side effects only when it creates the primary conversation' do
      created_ids = []

      first = described_class.resolve_primary!(contact_inbox: contact_inbox, attributes: attributes) do |conversation|
        created_ids << conversation.id
      end
      second = described_class.resolve_primary!(contact_inbox: contact_inbox, attributes: attributes) do |conversation|
        created_ids << conversation.id
      end

      expect(second).to eq(first)
      expect(created_ids).to eq([first.id])
    end
  end

  describe '#perform' do
    it 'keeps distinct explicit identity keys separate without claiming legacy records' do
      legacy = create(:conversation, contact_inbox: contact_inbox)

      first = described_class.new(
        contact_inbox: contact_inbox,
        identity_key: 'email:root-message-1',
        attributes: attributes
      ).perform
      second = described_class.new(
        contact_inbox: contact_inbox,
        identity_key: 'email:root-message-2',
        attributes: attributes
      ).perform

      expect([first.identity_key, second.identity_key]).to contain_exactly('email:root-message-1', 'email:root-message-2')
      expect(legacy.reload.identity_key).to be_nil
      expect(contact_inbox.conversations.count).to eq(3)
    end

    it 'reloads a stale contact inbox before deriving the domain identity' do
      current_contact = create(:contact, account: account)
      contact_inbox.update_column(:contact_id, current_contact.id) # rubocop:disable Rails/SkipsModelValidations

      conversation = described_class.resolve_primary!(contact_inbox: contact_inbox, attributes: attributes)

      expect(conversation.contact).to eq(current_contact)
      expect(conversation.contact_inbox).to eq(contact_inbox.reload)
    end

    it 'rejects a blank identity key' do
      resolver = described_class.new(contact_inbox: contact_inbox, identity_key: ' ', attributes: attributes)

      expect { resolver.perform }.to raise_error(ArgumentError, 'identity_key is required')
    end
  end
end
