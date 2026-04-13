require 'rails_helper'

RSpec.describe Outbound::ContactInboxResolver do
  describe '#perform' do
    let(:account) { create(:account) }
    let(:contact) { create(:contact, account: account, additional_attributes: { 'social_telegram_user_id' => 4242 }) }
    let(:inbox) { create(:channel_telegram_personal, account: account).inbox }

    it 'resolves and creates a contact inbox through the shared target resolver path' do
      contact_inbox = described_class.new(inbox: inbox, contact: contact).perform

      expect(contact_inbox).to be_present
      expect(contact_inbox.contact).to eq(contact)
      expect(contact_inbox.inbox).to eq(inbox)
      expect(contact_inbox.source_id).to eq('4242')
    end

    it 'reuses the latest contact inbox for the contact when one already exists' do
      existing_contact_inbox = create(:contact_inbox, contact: contact, inbox: inbox, source_id: 'existing-telegram-user')

      contact_inbox = described_class.new(inbox: inbox, contact: contact).perform

      expect(contact_inbox).to eq(existing_contact_inbox)
    end
  end
end
