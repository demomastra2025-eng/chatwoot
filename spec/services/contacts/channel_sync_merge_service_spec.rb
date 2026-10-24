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

    # One person, one status: the status tabs read only the status of the thread, so the merged thread gets the most urgent
    # status of the channels it has now, and one open dialog, at once (not at the next message).
    context 'when communication threads are on' do
      let(:agent) { create(:user, account: account, role: :administrator) }
      let(:wa_inbox) { create(:inbox, account: account) }
      let(:tg_inbox) { create(:inbox, account: account) }

      before do
        account.enable_features!('communication_threads')
        Current.account = account
      end

      after { Current.reset }

      def channel(contact, inbox, status, minutes_ago: 5)
        create(:conversation, account: account, contact: contact, inbox: inbox, status: :resolved,
                              contact_inbox: create(:contact_inbox, contact: contact, inbox: inbox)).tap do |conversation|
          conversation.update_columns(status: Conversation.statuses.fetch(status), last_activity_at: minutes_ago.minutes.ago) # rubocop:disable Rails/SkipsModelValidations
          Conversations::CommunicationThreadResolver.new(conversation: conversation.reload, enforce_single_open_dialog: false).perform
        end
      end

      def tab(status)
        CommunicationThreadFinder.new(agent, { status: status, assignee_type: 'all' }).perform
      end

      def merge_source_into_target
        ActiveRecord::Base.transaction do
          described_class.new(source_contact: source_contact, target_contact: target_contact) { target_contact.name }.perform
        end
      end

      it 'moves a person who is waiting in the merged-in channel from resolved to open', :aggregate_failures do
        channel(target_contact, wa_inbox, :resolved)
        waiting = channel(source_contact, tg_inbox, :open)
        target_thread = CommunicationThread.find_by!(account: account, contact: target_contact)
        expect(tab('open')[:count][:all_count]).to eq(1)
        expect(tab('resolved')[:communication_threads].map(&:id)).to eq([target_thread.id])

        expect(merge_source_into_target).to be(true)

        expect(target_thread.reload.conversations).to include(waiting)
        expect(target_thread.status).to eq('open')
        expect(tab('open')[:communication_threads].map(&:id)).to eq([target_thread.id])
        expect(tab('open')[:count][:all_count]).to eq(1)
        expect(tab('resolved')[:communication_threads]).to be_empty
        expect(tab('resolved')[:count][:all_count]).to eq(0)
      end

      status_matrix = [%w[snoozed open open], %w[resolved snoozed snoozed], %w[resolved pending pending], %w[snoozed pending pending]]
      tab_statuses = %w[open pending snoozed resolved]
      status_matrix.each do |target_status, source_status, person_status|
        it "gives a #{target_status} target and a #{source_status} source the status #{person_status}", :aggregate_failures do
          channel(target_contact, wa_inbox, target_status)
          channel(source_contact, tg_inbox, source_status)

          expect(merge_source_into_target).to be(true)

          thread = CommunicationThread.find_by!(account: account, contact: target_contact)
          expect(thread.status).to eq(person_status)
          expect(tab(person_status)[:communication_threads].map(&:id)).to eq([thread.id])
          (tab_statuses - [person_status]).each do |status|
            expect(tab(status)[:communication_threads]).to be_empty, "tab #{status}"
          end
        end
      end

      it 'keeps one open dialog when both contacts brought an open one', :aggregate_failures do
        older = channel(target_contact, wa_inbox, :open, minutes_ago: 120)
        newer = channel(source_contact, tg_inbox, :open, minutes_ago: 1)

        expect(merge_source_into_target).to be(true)

        thread = CommunicationThread.find_by!(account: account, contact: target_contact)
        expect(thread.conversations.where(status: %w[open pending]).pluck(:id)).to eq([newer.id])
        expect(older.reload).to be_resolved
        expect(thread.reload.status).to eq('open')
      end

      it 'does not touch the status of an account without communication threads', :aggregate_failures do
        channel(target_contact, wa_inbox, :resolved)
        channel(source_contact, tg_inbox, :open)
        account.disable_features!('communication_threads')
        thread = CommunicationThread.find_by!(account: account, contact: target_contact)

        expect(merge_source_into_target).to be(true)

        expect(thread.reload.status).to eq('resolved')
      end
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
