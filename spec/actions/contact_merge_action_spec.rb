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

    context 'when mergee contact has communication threads' do
      it 'moves the communication threads to base contact' do
        thread = create(:communication_thread, account: account, contact: mergee_contact)

        contact_merge

        expect(thread.reload.contact_id).to eq(base_contact.id)
        expect(CommunicationThread.exists?(thread.id)).to be true
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

    context 'when mergee contact has operational relations' do
      it 'moves scheduling, telephony, confirmation, reminder, lead, and assignment records' do
        appointment = create(:scheduling_appointment, account: account, contact: mergee_contact)
        call_session = create(:telephony_call_session, account: account, contact: mergee_contact)
        confirmation = create(:confirmation_request, account: account, contact: mergee_contact)
        reminder_conversation = create(:conversation, account: account, contact: mergee_contact)
        reminder = create(:reminder, account: account, touch_conversation: reminder_conversation)
        lead = create(:lead_submission, account: account, contact: mergee_contact)
        ownership = create(:assignment_client_ownership, account: account, contact: mergee_contact)

        contact_merge

        expect(appointment.reload.contact_id).to eq(base_contact.id)
        expect(call_session.reload.contact_id).to eq(base_contact.id)
        expect(confirmation.reload.contact_id).to eq(base_contact.id)
        expect(reminder.reload.target_contact_id).to eq(base_contact.id)
        expect(lead.reload.contact_id).to eq(base_contact.id)
        expect(ownership.reload.contact_id).to eq(base_contact.id)
      end
    end

    context 'when both contacts have the same assignment quota identity' do
      it 'keeps one quota record and preserves the merge transaction' do
        user = create(:user, account: account)
        period_start = Time.zone.today.beginning_of_month
        create(:assignment_quota_usage, account: account, user: user, contact: base_contact, period_start: period_start)
        create(:assignment_quota_usage, account: account, user: user, contact: mergee_contact, period_start: period_start)

        contact_merge

        expect(AssignmentQuotaUsage.where(account: account, user: user, contact: base_contact, period_start: period_start).count).to eq(1)
      end
    end

    context 'when both contacts have assignment ownership' do
      it 'blocks the merge instead of silently dropping ownership' do
        create(:assignment_client_ownership, account: account, contact: base_contact)
        mergee_ownership = create(:assignment_client_ownership, account: account, contact: mergee_contact)

        expect { contact_merge }.to raise_error(Contacts::ReferenceMergeService::UnsafeMergeError, /assignment ownership/)

        expect(mergee_ownership.reload.contact_id).to eq(mergee_contact.id)
        expect(mergee_contact.reload).to be_present
      end
    end

    context 'when both contacts have delivery history for the same campaign run' do
      it 'blocks the merge instead of deleting a delivery record' do
        campaign = create(:campaign, account: account)
        campaign_run = create(:campaign_run, campaign: campaign, account: account, inbox: campaign.inbox)
        create(:campaign_delivery, campaign: campaign, campaign_run: campaign_run, account: account,
                                   inbox: campaign.inbox, contact: base_contact)
        mergee_delivery = create(:campaign_delivery, campaign: campaign, campaign_run: campaign_run, account: account,
                                                     inbox: campaign.inbox, contact: mergee_contact)

        expect { contact_merge }.to raise_error(Contacts::ReferenceMergeService::UnsafeMergeError, /delivery history/)

        expect(mergee_delivery.reload.contact_id).to eq(mergee_contact.id)
        expect(mergee_contact.reload).to be_present
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
