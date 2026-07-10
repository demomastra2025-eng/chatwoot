require 'rails_helper'

RSpec.describe Reminders::CampaignConflictPolicy do
  describe '#conflict?' do
    let(:account) { create(:account) }
    let(:inbox) { create(:inbox, account: account) }
    let(:contact) { create(:contact, account: account) }
    let(:contact_inbox) { create(:contact_inbox, contact: contact, inbox: inbox) }
    let(:conversation) { create(:conversation, account: account, inbox: inbox, contact: contact, contact_inbox: contact_inbox) }
    let(:campaign) { create(:campaign, account: account, inbox: inbox) }
    let(:reminder) do
      create(
        :reminder,
        account: account,
        touch_conversation: conversation,
        conversation: conversation,
        remindable: conversation,
        metadata: { 'touch_source' => 'automation', 'automation_rule_id' => 42 }
      )
    end

    it 'blocks automation touches while a sent campaign has no later customer reply' do
      travel_to(Time.zone.parse('2026-05-05 10:00:00 UTC')) do
        create(:campaign_delivery, campaign: campaign, account: account, inbox: inbox, contact: contact, status: :sent,
                                   last_status_at: 10.minutes.ago)

        expect(described_class.new(reminder: reminder, conversation: conversation)).to be_conflict
      end
    end

    it 'does not block after a later incoming customer reply in the same inbox' do
      travel_to(Time.zone.parse('2026-05-05 10:00:00 UTC')) do
        create(:campaign_delivery, campaign: campaign, account: account, inbox: inbox, contact: contact, status: :sent,
                                   last_status_at: 30.minutes.ago)
        create(
          :message,
          account: account,
          inbox: inbox,
          conversation: conversation,
          message_type: :incoming,
          sender: contact,
          private: false,
          created_at: 5.minutes.ago
        )

        expect(described_class.new(reminder: reminder, conversation: conversation)).not_to be_conflict
      end
    end

    it 'does not treat agent/outgoing messages as campaign-unblocking customer replies' do
      travel_to(Time.zone.parse('2026-05-05 10:00:00 UTC')) do
        create(:campaign_delivery, campaign: campaign, account: account, inbox: inbox, contact: contact, status: :sent,
                                   last_status_at: 30.minutes.ago)
        create(
          :message,
          account: account,
          inbox: inbox,
          conversation: conversation,
          message_type: :outgoing,
          sender: create(:user, account: account),
          private: false,
          created_at: 5.minutes.ago
        )

        expect(described_class.new(reminder: reminder, conversation: conversation)).to be_conflict
      end
    end

    it 'does not treat private customer notes as campaign-unblocking replies' do
      travel_to(Time.zone.parse('2026-05-05 10:00:00 UTC')) do
        create(:campaign_delivery, campaign: campaign, account: account, inbox: inbox, contact: contact, status: :sent,
                                   last_status_at: 30.minutes.ago)
        create(
          :message,
          account: account,
          inbox: inbox,
          conversation: conversation,
          message_type: :incoming,
          sender: contact,
          private: true,
          created_at: 5.minutes.ago
        )

        expect(described_class.new(reminder: reminder, conversation: conversation)).to be_conflict
      end
    end

    it 'blocks not-yet-sent campaign deliveries for the same contact and same inbox' do
      create(:campaign_delivery, campaign: campaign, account: account, inbox: inbox, contact: contact, status: :pending)

      expect(described_class.new(reminder: reminder, conversation: conversation)).to be_conflict
    end

    it 'does not block campaign deliveries for the same contact in a different inbox' do
      other_inbox = create(:inbox, account: account)
      other_campaign = create(:campaign, account: account, inbox: other_inbox)
      create(:campaign_delivery, campaign: other_campaign, account: account, inbox: other_inbox, contact: contact, status: :pending)

      expect(described_class.new(reminder: reminder, conversation: conversation)).not_to be_conflict
    end

    it 'does not let an older worker cancel a newer processing claim' do
      create(:campaign_delivery, campaign: campaign, account: account, inbox: inbox, contact: contact, status: :pending)
      current_claim = reminder.mark_processing!

      result = described_class.new(
        reminder: reminder,
        conversation: conversation,
        processing_claim: 'stale-claim'
      ).cancel_if_conflict!

      expect(result).to be(false)
      expect(reminder.reload).to be_processing
      expect(reminder.processing_claim_token).to eq(current_claim)
    end

    it 'does not override a reminder that another cancellation path already finalized' do
      create(:campaign_delivery, campaign: campaign, account: account, inbox: inbox, contact: contact, status: :pending)
      reminder.update!(status: :processing)
      reminder.cancel!('cancelled by incoming reply')

      result = described_class.new(reminder: reminder, conversation: conversation).cancel_if_conflict!

      expect(result).to be(false)
      expect(reminder.reload).to be_cancelled
      expect(reminder.last_error).to eq('cancelled by incoming reply')
    end

    it 'does not block campaign deliveries for a different contact in the same inbox' do
      other_contact = create(:contact, account: account)
      create(:campaign_delivery, campaign: campaign, account: account, inbox: inbox, contact: other_contact, status: :pending)

      expect(described_class.new(reminder: reminder, conversation: conversation)).not_to be_conflict
    end
  end
end
