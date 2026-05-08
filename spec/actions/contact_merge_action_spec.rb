require 'rails_helper'

describe ContactMergeAction do
  subject(:contact_merge) { described_class.new(account: account, base_contact: base_contact, mergee_contact: mergee_contact).perform }

  let!(:account) { create(:account) }
  let!(:base_contact) do
    create(:contact, identifier: 'base_contact', email: 'old@old.com', phone_number: '', custom_attributes: { val_test: 'old', val_empty_old: '' },
                     account: account)
  end
  let!(:mergee_contact) do
    create(:contact, identifier: '', email: 'new@new.com', phone_number: '+12212345',
                     custom_attributes: { val_test: 'new', val_new: 'new', val_empty_new: '' }, account: account)
  end

  before do
    2.times.each do
      create(:conversation, contact: base_contact)
      create(:conversation, contact: mergee_contact)
      create(:message, sender: mergee_contact)
      create(:note, contact: mergee_contact, account: mergee_contact.account)
    end
    create(:contact_channel_profile, contact: mergee_contact, contact_inbox: mergee_contact.contact_inboxes.first)
  end

  describe '#perform' do
    it 'deletes mergee_contact' do
      contact_merge
      expect { mergee_contact.reload }.to raise_error(ActiveRecord::RecordNotFound)
    end

    it 'copies information from mergee contact to base contact' do
      contact_merge
      base_contact.reload
      expect(base_contact.identifier).to eq('base_contact')
      expect(base_contact.email).to eq('old@old.com')
      expect(base_contact.phone_number).to eq('+12212345')
      expect(base_contact.custom_attributes['val_test']).to eq('old')
      expect(base_contact.custom_attributes['val_new']).to eq('new')
      expect(base_contact.custom_attributes['val_empty_old']).to eq('')
      expect(base_contact.custom_attributes['val_empty_new']).to eq('')
    end

    context 'when base contact and merge contact are same' do
      it 'does not delete contact' do
        mergee_contact = base_contact
        contact_merge
        expect(mergee_contact.reload).not_to be_nil
      end
    end

    context 'when mergee contact has conversations' do
      it 'moves the conversations to base contact' do
        contact_merge
        expect(base_contact.conversations.count).to be 4
      end
    end

    context 'when mergee contact has contact inboxes' do
      it 'moves the contact inboxes to base contact' do
        contact_merge
        expect(base_contact.contact_inboxes.count).to be 4
      end
    end

    context 'when mergee contact has channel profiles' do
      it 'moves the channel profiles to base contact' do
        contact_merge
        expect(base_contact.contact_channel_profiles.count).to be 1
      end
    end

    context 'when mergee contact has messages' do
      it 'moves the messages to base contact' do
        contact_merge
        expect(base_contact.messages.count).to be 2
      end
    end

    context 'when mergee contact has CRM deal links' do
      it 'moves unique deal links and deduplicates shared deal links' do
        unique_deal = create(:crm_deal, account: account)
        shared_deal = create(:crm_deal, account: account)
        create(:crm_deal_contact, account: account, deal: unique_deal, contact: mergee_contact, primary: true)
        create(:crm_deal_contact, account: account, deal: shared_deal, contact: base_contact, primary: false)
        create(:crm_deal_contact, account: account, deal: shared_deal, contact: mergee_contact, primary: true)

        contact_merge

        expect(unique_deal.deal_contacts.reload.pluck(:contact_id)).to contain_exactly(base_contact.id)
        shared_links = shared_deal.deal_contacts.reload
        expect(shared_links.pluck(:contact_id)).to contain_exactly(base_contact.id)
        expect(shared_links.first.primary).to be(true)
      end

      it 'keeps an existing base primary deal link when removing duplicate mergee link' do
        shared_deal = create(:crm_deal, account: account)
        create(:crm_deal_contact, account: account, deal: shared_deal, contact: base_contact, primary: true)
        create(:crm_deal_contact, account: account, deal: shared_deal, contact: mergee_contact, primary: false)

        contact_merge

        shared_links = shared_deal.deal_contacts.reload
        expect(shared_links.pluck(:contact_id)).to contain_exactly(base_contact.id)
        expect(shared_links.first.primary).to be(true)
      end
    end

    context 'when mergee contact has notes' do
      it 'moves the notes to base contact' do
        expect(base_contact.notes.count).to be 0
        expect(mergee_contact.notes.count).to be 2

        contact_merge

        expect(base_contact.reload.notes.count).to be 2
      end
    end

    context 'when contacts belong to a different account' do
      it 'throws an exception' do
        new_account = create(:account)
        expect do
          described_class.new(account: new_account, base_contact: base_contact,
                              mergee_contact: mergee_contact).perform
        end.to raise_error('contact does not belong to the account')
      end
    end
  end
end
