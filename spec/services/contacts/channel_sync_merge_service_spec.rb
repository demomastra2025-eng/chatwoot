# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Contacts::ChannelSyncMergeService do
  let(:account) { create(:account) }
  let(:target_contact) do
    create(:contact, account: account, name: 'Алия Нурланова', phone_number: '+77015551122')
  end
  let(:source_contact) do
    create(
      :contact,
      account: account,
      name: '143907392331785@lid',
      phone_number: nil,
      identifier: 'whatsapp_web:143907392331785@lid',
      additional_attributes: {
        'channel_profiles' => {
          'whatsapp_web' => {
            'whatsapp_web:143907392331785@lid' => { 'source_id' => '143907392331785@lid' }
          }
        }
      }
    )
  end

  describe '#perform' do
    it 'consolidates communication threads when both contacts already have a thread', :aggregate_failures do
      wa_inbox = create(:inbox, account: account)
      tg_inbox = create(:inbox, account: account)
      target_ci = create(:contact_inbox, contact: target_contact, inbox: wa_inbox)
      source_ci = create(:contact_inbox, contact: source_contact, inbox: tg_inbox)

      target_conv = create(:conversation, account: account, inbox: wa_inbox, contact: target_contact, contact_inbox: target_ci)
      source_conv = create(:conversation, account: account, inbox: tg_inbox, contact: source_contact, contact_inbox: source_ci)

      target_thread = Conversations::CommunicationThreadResolver.new(conversation: target_conv).perform
      source_thread = Conversations::CommunicationThreadResolver.new(conversation: source_conv).perform
      deal = create(:crm_deal, account: account, originating_communication_thread: source_thread)

      merged = ActiveRecord::Base.transaction do
        described_class.new(source_contact: source_contact, target_contact: target_contact) { target_contact.name }.perform
      end

      expect(merged).to be(true)
      expect(Contact.exists?(source_contact.id)).to be(false)
      expect(CommunicationThread.exists?(source_thread.id)).to be(false)
      expect(CommunicationThread.where(account: account, contact: target_contact).pluck(:id)).to eq([target_thread.id])
      expect(target_thread.reload.conversations.pluck(:id)).to contain_exactly(target_conv.id, source_conv.id)
      expect(deal.reload.originating_communication_thread_id).to eq(target_thread.id)
    end

    it 'keeps the labels of the merged-away card on the person', :aggregate_failures do
      wa_inbox = create(:inbox, account: account)
      tg_inbox = create(:inbox, account: account)
      target_ci = create(:contact_inbox, contact: target_contact, inbox: wa_inbox)
      source_ci = create(:contact_inbox, contact: source_contact, inbox: tg_inbox)
      target_conv = create(:conversation, account: account, inbox: wa_inbox, contact: target_contact, contact_inbox: target_ci)
      source_conv = create(:conversation, account: account, inbox: tg_inbox, contact: source_contact, contact_inbox: source_ci)
      target_contact.update_labels(%w[target_card])
      source_contact.update_labels(%w[source_card])
      source_conv.update_labels(%w[source_channel])
      union = %w[target_card source_card source_channel]

      merged = ActiveRecord::Base.transaction do
        described_class.new(source_contact: source_contact, target_contact: target_contact) { target_contact.name }.perform
      end

      expect(merged).to be(true)
      expect(target_contact.reload.label_list).to match_array(union)
      expect(target_conv.reload.label_list).to match_array(union)
      expect(source_conv.reload.label_list).to match_array(union)
    end

    it 'reassigns CRM deal links, telephony call sessions, and consolidates duplicate same-inbox dialogs', :aggregate_failures do
      inbox = create(:inbox, account: account)
      target_ci = create(:contact_inbox, contact: target_contact, inbox: inbox)
      source_ci = create(:contact_inbox, contact: source_contact, inbox: inbox)

      create(:conversation, account: account, inbox: inbox, contact: target_contact, contact_inbox: target_ci)
      create(:conversation, account: account, inbox: inbox, contact: source_contact, contact_inbox: source_ci)

      shared_deal = create(:crm_deal, account: account)
      unique_deal = create(:crm_deal, account: account)
      create(:crm_deal_contact, account: account, deal: shared_deal, contact: target_contact, primary: false)
      create(:crm_deal_contact, account: account, deal: shared_deal, contact: source_contact, primary: true)
      create(:crm_deal_contact, account: account, deal: unique_deal, contact: source_contact, primary: true)
      call_session = create(:telephony_call_session, account: account, contact: source_contact)

      merged = ActiveRecord::Base.transaction do
        described_class.new(source_contact: source_contact, target_contact: target_contact) { target_contact.name }.perform
      end

      expect(merged).to be(true)
      expect(Conversation.where(account: account, contact: target_contact, inbox: inbox).count).to eq(1)
      expect(shared_deal.deal_contacts.reload.pluck(:contact_id, :primary)).to eq([[target_contact.id, true]])
      expect(unique_deal.deal_contacts.reload.pluck(:contact_id, :primary)).to eq([[target_contact.id, true]])
      expect(call_session.reload.contact_id).to eq(target_contact.id)
    end

    it 'returns false without mutating contacts when ReferenceMergeService detects an unsafe collision', :aggregate_failures do
      create(:assignment_client_ownership, account: account, contact: target_contact)
      source_ownership = create(:assignment_client_ownership, account: account, contact: source_contact)

      merged = ActiveRecord::Base.transaction do
        described_class.new(source_contact: source_contact, target_contact: target_contact) { target_contact.name }.perform
      end

      expect(merged).to be(false)
      expect(Contact.exists?(source_contact.id)).to be(true)
      expect(source_ownership.reload.contact_id).to eq(source_contact.id)
    end
  end
end
