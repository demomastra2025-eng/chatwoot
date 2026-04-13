require 'rails_helper'

RSpec.describe Campaigns::AudienceResolver do
  subject(:resolver) { described_class.new(account: account, audience: audience) }

  let(:account) { create(:account) }
  let(:label_1) { create(:label, account: account, title: 'vip') }
  let(:label_2) { create(:label, account: account, title: 'new') }
  let(:audience) do
    [
      { type: 'Label', id: label_1.id },
      { type: 'Label', id: label_2.id }
    ]
  end

  describe '#contacts' do
    it 'returns distinct contacts matching any selected label' do
      contact_1 = create(:contact, account: account)
      contact_2 = create(:contact, account: account)
      contact_3 = create(:contact, account: account)

      contact_1.update_labels([label_1.title])
      contact_2.update_labels([label_2.title])
      contact_3.update_labels([label_1.title, label_2.title])

      expect(resolver.contacts.pluck(:id)).to match_array([contact_1.id, contact_2.id, contact_3.id])
    end

    it 'includes contacts whose conversations carry the selected labels' do
      contact_1 = create(:contact, account: account)
      contact_2 = create(:contact, account: account)
      contact_3 = create(:contact, account: account)
      inbox = create(:inbox, account: account, channel: create(:channel_telegram_personal, account: account))

      create(:conversation, account: account, inbox: inbox, contact: contact_1, contact_inbox: create(:contact_inbox, inbox: inbox, contact: contact_1)).update_labels([label_1.title])
      create(:conversation, account: account, inbox: inbox, contact: contact_2, contact_inbox: create(:contact_inbox, inbox: inbox, contact: contact_2)).update_labels([label_2.title])
      create(:conversation, account: account, inbox: inbox, contact: contact_3, contact_inbox: create(:contact_inbox, inbox: inbox, contact: contact_3)).update_labels([label_1.title, label_2.title])

      expect(resolver.contacts.pluck(:id)).to match_array([contact_1.id, contact_2.id, contact_3.id])
    end

    it 'deduplicates contacts tagged directly and through conversations' do
      contact = create(:contact, account: account)
      inbox = create(:inbox, account: account, channel: create(:channel_telegram_personal, account: account))

      contact.update_labels([label_1.title])
      create(:conversation, account: account, inbox: inbox, contact: contact, contact_inbox: create(:contact_inbox, inbox: inbox, contact: contact)).update_labels([label_1.title])

      expect(resolver.contacts.pluck(:id)).to eq([contact.id])
    end

    it 'returns an empty relation for blank audience' do
      empty_resolver = described_class.new(account: account, audience: nil)

      expect(empty_resolver.contacts).to be_empty
    end
  end
end
