require 'rails_helper'

RSpec.describe Crm::Deals::ContactScope do
  let(:account) { create(:account) }
  let(:contact) { create(:contact, account: account) }

  describe '.resolve' do
    it 'returns deals linked to the contact across explicit, conversation, and thread relations' do
      linked_deal = create(:crm_deal, account: account)
      create(:crm_deal_contact, account: account, deal: linked_deal, contact: contact, primary: true)

      conversation = create(:conversation, account: account, contact: contact)
      conversation_deal = create(:crm_deal, account: account, originating_conversation: conversation)

      communication_thread = create(:communication_thread, account: account, contact: contact)
      thread_deal = create(:crm_deal, account: account, originating_communication_thread: communication_thread)

      expect(described_class.resolve(account: account, contact: contact)).to contain_exactly(
        linked_deal,
        conversation_deal,
        thread_deal
      )
    end

    it 'excludes deals linked only to another contact or account' do
      other_contact = create(:contact, account: account)
      other_contact_deal = create(:crm_deal, account: account)
      create(:crm_deal_contact, account: account, deal: other_contact_deal, contact: other_contact, primary: true)

      other_account = create(:account)
      cross_account_contact = create(:contact, account: other_account)
      cross_account_deal = create(:crm_deal, account: other_account)
      create(
        :crm_deal_contact,
        account: other_account,
        deal: cross_account_deal,
        contact: cross_account_contact,
        primary: true
      )

      expect(described_class.resolve(account: account, contact: contact)).to be_empty
      expect(described_class.resolve(account: account, contact: cross_account_contact)).to be_empty
    end

    it 'fails closed without an authoritative account contact' do
      expect(described_class.resolve(account: account, contact: nil)).to be_empty
      expect(described_class.resolve(account: nil, contact: contact)).to be_empty
    end
  end
end
