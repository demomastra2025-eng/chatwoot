require 'rails_helper'

RSpec.describe Captain::Tools::Operations::TouchOperations do
  let(:account) { create(:account) }
  let(:assistant) { create(:captain_assistant, account: account) }
  let(:user) { create(:user, account: account, role: :administrator) }
  let(:conversation) { create(:conversation, account: account) }

  describe '#create_touch' do
    it 'creates a draft touch for the current conversation by default' do
      touch = described_class.new(
        assistant: assistant,
        conversation: conversation,
        actor: user
      ).create_touch(
        body: 'Follow up tomorrow',
        scheduled_at: 1.day.from_now.iso8601
      )

      expect(touch).to be_persisted
      expect(touch.status).to eq('draft')
      expect(touch.remindable).to eq(conversation)
      expect(touch.target_inbox).to eq(conversation.inbox)
      expect(touch.metadata['touch_source']).to eq('captain')
    end

    it 'supports relative scheduling for linked deal context' do
      deal = create(:crm_deal, account: account, expected_close_on: Date.current + 3.days)
      create(:crm_deal_contact, deal: deal, contact: conversation.contact, account: account)
      allow(Captain::ContextFields).to receive(:deal_for).and_return(deal)

      touch = described_class.new(
        assistant: assistant,
        conversation: conversation,
        actor: user
      ).create_touch(
        body: 'Close date follow-up',
        remindable_kind: 'deal',
        relative_anchor: 'deal.expected_close_on',
        relative_offset_minutes: -60
      )

      expect(touch.remindable).to eq(deal)
      expect(touch.timing_mode).to eq('relative')
      expect(touch.relative_anchor).to eq('deal.expected_close_on')
      expect(touch.relative_offset_seconds).to eq(-3600)
    end

    it 'uses the same template detection pattern for touch bodies' do
      touch = described_class.new(
        assistant: assistant,
        conversation: conversation,
        actor: user
      ).create_touch(
        body: 'Follow up with {{contact.name}}',
        scheduled_at: 1.day.from_now.iso8601
      )

      expect(touch.text_mode).to eq('dynamic')
    end

    it 'raises when the selected context is unavailable' do
      operation = described_class.new(assistant: assistant, conversation: conversation, actor: user)

      expect do
        operation.create_touch(
          body: 'Appointment reminder',
          remindable_kind: 'appointment',
          scheduled_at: 1.day.from_now.iso8601
        )
      end.to raise_error(ArgumentError, 'Current appointment is not available')
    end
  end
end
