require 'rails_helper'

RSpec.describe Reminders::ExecuteService do
  describe '#perform' do
    it 'materializes a touch into a normal outgoing message' do
      conversation = create(:conversation)
      touch = create(
        :reminder,
        account: conversation.account,
        touch_conversation: conversation,
        conversation: conversation,
        remindable: conversation,
        status: :processing,
        body: 'Hello {{contact.name}}'
      )

      expect do
        described_class.new(reminder: touch).perform
      end.to change { conversation.messages.outgoing.count }.by(1)

      expect(touch.reload).to be_completed
      message = conversation.messages.outgoing.last
      expect(message.additional_attributes['touch_id']).to eq(touch.id)
      expect(message.content).to include(conversation.contact.name)
    end

    it 'materializes an agent touch using Captain-generated content' do
      conversation = create(:conversation)
      assistant = create(:captain_assistant, account: conversation.account)
      touch = create(
        :reminder,
        account: conversation.account,
        touch_conversation: conversation,
        conversation: conversation,
        remindable: conversation,
        status: :processing,
        text_mode: :agent,
        body: nil,
        instructions: 'Write a short follow-up reminder',
        metadata: { 'captain_assistant_id' => assistant.id }
      )

      allow_any_instance_of(Reminders::CaptainGeneratedMessageService)
        .to receive(:perform)
        .and_return(
          content: 'Generated follow-up',
          assistant: assistant,
          captain_trace: { 'steps' => [] }
        )

      described_class.new(reminder: touch).perform

      message = conversation.messages.outgoing.last
      expect(touch.reload).to be_completed
      expect(message.content).to eq('Generated follow-up')
      expect(message.additional_attributes['captain_trace']).to eq({ 'steps' => [] })
    end

    it 'wakes up Captain and creates an assistant message for ai_agent_wakeup touches' do
      conversation = create(:conversation, status: :open)
      assistant = create(:captain_assistant, account: conversation.account)
      touch = create(
        :reminder,
        account: conversation.account,
        touch_conversation: conversation,
        conversation: conversation,
        remindable: conversation,
        status: :processing,
        action_type: :ai_agent_wakeup,
        metadata: { 'captain_assistant_id' => assistant.id }
      )

      allow_any_instance_of(Reminders::CaptainGeneratedMessageService)
        .to receive(:perform)
        .and_return(
          content: 'Captain wakeup message',
          assistant: assistant,
          captain_trace: { 'steps' => ['generated'] }
        )

      described_class.new(reminder: touch).perform

      message = conversation.messages.outgoing.last
      expect(touch.reload).to be_completed
      expect(conversation.reload).to be_pending
      expect(message.sender).to eq(assistant)
      expect(message.content).to eq('Captain wakeup message')
    end

    it 'creates the next recurring touch after successful execution' do
      conversation = create(:conversation)
      scheduled_at = Time.zone.parse('2026-04-13 13:00:00 UTC')
      touch = create(
        :reminder,
        account: conversation.account,
        touch_conversation: conversation,
        conversation: conversation,
        remindable: conversation,
        status: :processing,
        scheduled_at: scheduled_at,
        repeat_mode: :weekly,
        repeat_until_at: scheduled_at + 1.month,
        body: 'Weekly check-in'
      )

      expect do
        described_class.new(reminder: touch).perform
      end.to change { conversation.account.reminders.count }.by(1)

      next_touch = conversation.account.reminders.where.not(id: touch.id).order(:created_at).last

      expect(touch.reload).to be_completed
      expect(next_touch).to be_present
      expect(next_touch).to be_pending
      expect(next_touch.repeat_mode).to eq('weekly')
      expect(next_touch.scheduled_at.to_i).to eq((scheduled_at + 1.week).to_i)
    end

    it 'delivers a personal reminder through telegram personal using the shared target resolution path' do
      account = create(:account)
      inbox = create(:channel_telegram_personal, account: account).inbox
      contact = create(
        :contact,
        account: account,
        additional_attributes: { 'social_telegram_user_id' => 4242 }
      )
      touch = Reminder.create!(
        account: account,
        creator: create(:user, account: account, role: :administrator),
        owner: account.administrators.first,
        status: :processing,
        body: 'Telegram follow-up',
        target_inbox: inbox,
        target_contact: contact,
        conversation: nil,
        remindable: nil,
        target_conversation: nil,
        target_contact_inbox: nil
      )

      expect do
        described_class.new(reminder: touch).perform
      end.to change { inbox.messages.outgoing.count }.by(1)

      expect(touch.reload).to be_completed
      expect(touch.target_conversation).to be_present
      expect(touch.target_contact_inbox).to be_present
      expect(touch.target_conversation.contact).to eq(contact)
      expect(touch.target_conversation.contact_inbox.source_id).to eq('4242')
    end
  end
end
