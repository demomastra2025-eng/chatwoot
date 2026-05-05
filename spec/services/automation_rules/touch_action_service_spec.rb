require 'rails_helper'

RSpec.describe AutomationRules::TouchActionService do
  let(:account) { create(:account) }
  let(:rule) { create(:automation_rule, account: account) }
  let(:inbox) { create(:inbox, account: account) }
  let(:contact) { create(:contact, account: account) }
  let(:contact_inbox) { create(:contact_inbox, contact: contact, inbox: inbox) }
  let(:conversation) { create(:conversation, account: account, inbox: inbox, contact: contact, contact_inbox: contact_inbox) }
  let(:service) { described_class.new(rule: rule, account: account, record: conversation, entity_kind: 'conversation') }

  describe '#create_touch' do
    it 'defaults auto-cancel off unless the automation action explicitly enables it' do
      touch = service.create_touch([{ body: 'Follow up later', delay_minutes: 10 }])

      expect(touch).to be_pending
      expect(touch.auto_cancel_on_incoming).to be(false)
      expect(touch.metadata).to include('touch_source' => 'automation', 'automation_rule_id' => rule.id)
    end

    it 'stores an explicit auto-cancel flag when enabled' do
      touch = service.create_touch([{ body: 'Follow up later', delay_minutes: 10, auto_cancel_on_incoming: true }])

      expect(touch.auto_cancel_on_incoming).to be(true)
      expect(touch.metadata).to include('auto_cancel_on_incoming_explicit' => true)
    end

    it 'immediately cancels an automation touch when a same-contact campaign delivery is blocking' do
      campaign = create(:campaign, account: account, inbox: inbox)
      create(:campaign_delivery, campaign: campaign, account: account, inbox: inbox, contact: contact, status: :pending)

      touch = service.create_touch([{ body: 'Do not duplicate campaign', delay_minutes: 10 }])

      expect(touch.reload).to be_cancelled
      expect(touch.last_error).to eq('отменен из-за рассылки')
    end
  end

  describe '#cancel_touches' do
    it 'cancels only draft and pending touches for the current entity with automation reason' do
      draft_touch = create(:reminder, account: account, touch_conversation: conversation, conversation: conversation, remindable: conversation,
                                      status: :draft, body: 'Draft touch')
      pending_touch = create(:reminder, account: account, touch_conversation: conversation, conversation: conversation, remindable: conversation,
                                        status: :pending, body: 'Pending touch')
      completed_touch = create(:reminder, account: account, touch_conversation: conversation, conversation: conversation, remindable: conversation,
                                          status: :completed, body: 'Completed touch')

      cancelled_count = service.cancel_touches([{}])

      expect(cancelled_count).to eq(2)
      expect(draft_touch.reload).to be_cancelled
      expect(pending_touch.reload).to be_cancelled
      expect(completed_touch.reload).to be_completed
      expect(pending_touch.last_error).to eq('отменен автоматизацией')
      expect(pending_touch.metadata).to include('cancelled_via' => 'automation_cancel_touches', 'cancel_touches_entity_kind' => 'conversation')
    end
  end
end
