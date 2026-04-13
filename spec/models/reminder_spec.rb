require 'rails_helper'

RSpec.describe Reminder do
  describe 'relative scheduling' do
    it 'materializes scheduled_at from the relative anchor' do
      conversation = create(:conversation)
      reminder = build(
        :reminder,
        account: conversation.account,
        touch_conversation: conversation,
        conversation: conversation,
        remindable: conversation,
        timing_mode: :relative,
        relative_anchor: 'conversation.created_at',
        relative_offset_seconds: 3600,
        scheduled_at: nil
      )

      reminder.validate

      expect(reminder.scheduled_at.to_i).to eq((conversation.created_at + 1.hour).to_i)
    end

    it 'materializes scheduled_at from the last outgoing conversation message' do
      conversation = create(:conversation)
      outgoing_message = create(
        :message,
        account: conversation.account,
        conversation: conversation,
        inbox: conversation.inbox,
        message_type: :outgoing,
        private: false
      )
      reminder = build(
        :reminder,
        account: conversation.account,
        touch_conversation: conversation,
        conversation: conversation,
        remindable: conversation,
        timing_mode: :relative,
        relative_anchor: 'conversation.last_outgoing_message_at',
        relative_offset_seconds: 1800,
        scheduled_at: nil
      )

      reminder.validate

      expect(reminder.scheduled_at.to_i).to eq(
        (outgoing_message.created_at + 30.minutes).to_i
      )
    end

    it 'materializes scheduled_at from waiting since when the conversation is awaiting a reply' do
      conversation = create(:conversation)
      reminder = build(
        :reminder,
        account: conversation.account,
        touch_conversation: conversation,
        conversation: conversation,
        remindable: conversation,
        timing_mode: :relative,
        relative_anchor: 'conversation.waiting_since',
        relative_offset_seconds: 900,
        scheduled_at: nil
      )

      reminder.validate

      expect(reminder.scheduled_at.to_i).to eq(
        (conversation.waiting_since + 15.minutes).to_i
      )
    end
  end

  describe 'duplicate protection' do
    it 'blocks duplicate open touches with the same fingerprint' do
      conversation = create(:conversation)
      scheduled_at = 1.hour.from_now.change(usec: 0)
      create(
        :reminder,
        account: conversation.account,
        touch_conversation: conversation,
        body: 'Same touch',
        scheduled_at: scheduled_at
      )
      duplicate = build(
        :reminder,
        account: conversation.account,
        touch_conversation: conversation,
        body: 'Same touch',
        scheduled_at: scheduled_at
      )

      expect(duplicate).not_to be_valid
      expect(duplicate.errors[:base]).to include('An open touch with the same content already exists')
    end
  end

  describe 'status defaults' do
    it 'falls back to draft when routing is incomplete' do
      account = create(:account)
      creator = create(:user, account: account, role: :administrator)
      reminder = described_class.new(
        account: account,
        creator: creator,
        owner: creator,
        action_type: :send_message,
        content_kind: :free_text,
        text_mode: :static,
        timing_mode: :absolute,
        scheduled_at: 1.hour.from_now,
        timezone: 'UTC',
        body: 'Draft me'
      )

      reminder.validate

      expect(reminder).to be_draft
    end

    it 'keeps agent touches pending when route and instructions are ready' do
      conversation = create(:conversation)
      reminder = build(
        :reminder,
        account: conversation.account,
        touch_conversation: conversation,
        conversation: conversation,
        remindable: conversation,
        text_mode: :agent,
        body: nil,
        instructions: 'Write a short and helpful follow-up'
      )

      reminder.validate

      expect(reminder).to be_pending
      expect(reminder).to be_ready_for_pending
    end
  end

  describe 'text mode normalization' do
    it 'detects Liquid syntax as dynamic automatically' do
      reminder = build(:reminder, body: 'Hello {{contact.name}}', text_mode: :static)

      reminder.validate

      expect(reminder.text_mode).to eq('dynamic')
    end

    it 'detects field references as dynamic automatically' do
      reminder = build(:reminder, body: 'Hello [Name](field://contact.name)')

      reminder.validate

      expect(reminder.text_mode).to eq('dynamic')
    end

    it 'ignores Liquid syntax inside code blocks for detection' do
      reminder = build(:reminder, body: 'Use `{{contact.name}}` as an example')

      reminder.validate

      expect(reminder.text_mode).to eq('static')
    end
  end

  describe 'repeat validation' do
    it 'rejects recurring relative touches' do
      conversation = create(:conversation)
      reminder = build(
        :reminder,
        account: conversation.account,
        touch_conversation: conversation,
        conversation: conversation,
        remindable: conversation,
        timing_mode: :relative,
        relative_anchor: 'conversation.created_at',
        relative_offset_seconds: 3600,
        scheduled_at: nil,
        repeat_mode: :weekly
      )

      expect(reminder).not_to be_valid
      expect(reminder.errors[:repeat_mode]).to include('is only supported for absolute touches')
    end
  end
end
