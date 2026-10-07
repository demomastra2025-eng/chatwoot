require 'rails_helper'

# An automated notification (reminder, touch, AI follow-up) must never open or otherwise change the status of a conversation:
# a closed conversation stays closed, and a conversation created only to carry the notification is created closed.
RSpec.describe Reminders::ExecuteService do
  let(:account) { create(:account) }
  let(:inbox) { create(:inbox, account: account) }
  let(:contact) { create(:contact, :with_email, account: account) }
  let(:contact_inbox) { create(:contact_inbox, contact: contact, inbox: inbox) }
  let!(:closed_conversation) do
    create(:conversation, account: account, inbox: inbox, contact: contact, contact_inbox: contact_inbox, status: :resolved)
  end

  def build_touch(**attributes)
    create(
      :reminder,
      account: account,
      touch_conversation: closed_conversation,
      conversation: closed_conversation,
      remindable: closed_conversation,
      status: :processing,
      body: 'Reminder text',
      **attributes
    )
  end

  def contact_conversations
    Conversation.where(account_id: account.id, contact_inbox_id: contact_inbox.id).order(:id)
  end

  def open_or_pending_conversations
    Conversation.where(account_id: account.id, status: %w[open pending])
  end

  context 'when the inbox does not keep one conversation per contact' do
    before { inbox.update!(lock_to_single_conversation: false) }

    it 'sends the touch into a new conversation that is created closed and leaves the closed ones closed', :aggregate_failures do
      touch = build_touch

      expect { described_class.new(reminder: touch).perform }.to change(contact_conversations, :count).by(1)

      carrier = contact_conversations.last
      expect(touch.reload).to be_completed
      expect(carrier).not_to eq(closed_conversation)
      expect(carrier).to be_resolved
      expect(carrier.additional_attributes).to include('outbound_automated' => true)
      expect(carrier.status_transitions).to be_empty
      expect(carrier.messages.outgoing.pluck(:content)).to eq(['Reminder text'])
      expect(carrier.messages.outgoing.sole.additional_attributes['touch_id']).to eq(touch.id)
      expect(touch.target_conversation).to eq(carrier)
      expect(closed_conversation.reload).to be_resolved
      expect(closed_conversation.messages.outgoing).to be_empty
      expect(open_or_pending_conversations).to be_empty
    end

    it 'sends the next touch into the same notification conversation instead of creating another one' do
      first_touch = build_touch(body: 'First reminder')
      described_class.new(reminder: first_touch).perform
      carrier = contact_conversations.last

      second_touch = build_touch(body: 'Second reminder')
      expect { described_class.new(reminder: second_touch).perform }.not_to(change(contact_conversations, :count))

      expect(carrier.reload).to be_resolved
      expect(carrier.messages.outgoing.order(:id).pluck(:content)).to eq(['First reminder', 'Second reminder'])
      expect(open_or_pending_conversations).to be_empty
    end

    it 'keeps a notification conversation closed when the touch comes from an automation rule' do
      rule = create(:automation_rule, account: account)
      touch = build_touch(body: 'Automated follow-up')
      touch.mark_automation_provenance!(rule)

      described_class.new(reminder: touch).perform

      carrier = contact_conversations.last
      expect(touch.reload).to be_completed
      expect(carrier).to be_resolved
      expect(carrier.messages.outgoing.sole.content_attributes).to include('automation_rule_id' => rule.id)
      expect(open_or_pending_conversations).to be_empty
    end

    it 'keeps a notification conversation closed when the touch is written by a Captain assistant' do
      assistant = create(:captain_assistant, account: account)
      touch = build_touch(
        text_mode: :agent,
        body: nil,
        instructions: 'Write a short follow-up reminder',
        metadata: { 'captain_assistant_id' => assistant.id }
      )
      generator = instance_double(Reminders::CaptainGeneratedMessageService)
      allow(Reminders::CaptainGeneratedMessageService).to receive(:new).and_return(generator)
      allow(generator).to receive(:perform).and_return(content: 'Generated follow-up', assistant: assistant, captain_trace: {})

      described_class.new(reminder: touch).perform

      carrier = contact_conversations.last
      expect(carrier).to be_resolved
      expect(carrier.messages.outgoing.sole).to have_attributes(content: 'Generated follow-up', sender: assistant)
      expect(open_or_pending_conversations).to be_empty
    end

    it 'does not raise a new-conversation event for the notification conversation' do
      allow(Rails.configuration.dispatcher).to receive(:dispatch).and_call_original
      touch = build_touch

      described_class.new(reminder: touch).perform

      expect(contact_conversations.last).not_to eq(closed_conversation)
      expect(Rails.configuration.dispatcher).not_to have_received(:dispatch).with(Events::Types::CONVERSATION_CREATED, any_args)
      expect(Rails.configuration.dispatcher).to have_received(:dispatch).with(Events::Types::MESSAGE_CREATED, any_args)
    end
  end

  context 'when the inbox keeps one conversation per contact' do
    before { inbox.update!(lock_to_single_conversation: true) }

    it 'sends the touch into the latest closed conversation without reopening it or creating another one', :aggregate_failures do
      latest = create(:conversation, account: account, inbox: inbox, contact: contact, contact_inbox: contact_inbox, status: :resolved)
      touch = build_touch

      expect { described_class.new(reminder: touch).perform }.not_to(change(contact_conversations, :count))

      expect(touch.reload).to be_completed
      expect(touch.target_conversation).to eq(latest)
      expect(latest.reload).to be_resolved
      expect(latest.messages.outgoing.pluck(:content)).to eq(['Reminder text'])
      expect(closed_conversation.reload).to be_resolved
      expect(closed_conversation.messages.outgoing).to be_empty
      expect(latest.status_transitions).to be_empty
      expect(open_or_pending_conversations).to be_empty
    end
  end

  context 'when the inbox has an active agent bot' do
    let(:bot_inbox) { create(:agent_bot_inbox) }
    let(:account) { bot_inbox.inbox.account }
    let(:inbox) { bot_inbox.inbox }

    before do
      inbox.update!(lock_to_single_conversation: false)
      # The bot starts every ordinary conversation as pending, so the earlier conversation is closed afterwards.
      closed_conversation.resolved!
    end

    it 'creates the notification conversation closed instead of pending' do
      expect(inbox.reload).to be_active_bot
      touch = build_touch

      expect { described_class.new(reminder: touch).perform }.to change(contact_conversations, :count).by(1)

      carrier = contact_conversations.last
      expect(carrier).to be_resolved
      expect(carrier.messages.outgoing.sole.content).to eq('Reminder text')
      expect(open_or_pending_conversations).to be_empty
    end
  end

  context 'when the contact has an open conversation' do
    it 'sends the touch into it and keeps its status' do
      open_conversation = create(:conversation, account: account, inbox: inbox, contact: contact, contact_inbox: contact_inbox, status: :open)
      touch = build_touch

      expect { described_class.new(reminder: touch).perform }.not_to(change(contact_conversations, :count))

      expect(open_conversation.reload).to be_open
      expect(open_conversation.messages.outgoing.pluck(:content)).to eq(['Reminder text'])
      expect(closed_conversation.reload).to be_resolved
    end
  end

  context 'with an ai_agent_wakeup touch' do
    it 'still moves a closed conversation to pending so that the AI continues the chat' do
      assistant = create(:captain_assistant, account: account)
      touch = build_touch(action_type: :ai_agent_wakeup, metadata: { 'captain_assistant_id' => assistant.id })
      generator = instance_double(Reminders::CaptainGeneratedMessageService)
      allow(Reminders::CaptainGeneratedMessageService).to receive(:new).and_return(generator)
      allow(generator).to receive(:perform).and_return(content: 'Captain wakeup message', assistant: assistant, captain_trace: {})

      described_class.new(reminder: touch).perform

      expect(touch.reload).to be_completed
      expect(closed_conversation.reload).to be_pending
      expect(closed_conversation.messages.outgoing.sole).to have_attributes(content: 'Captain wakeup message', sender: assistant)
    end
  end
end
