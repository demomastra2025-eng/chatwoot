require 'rails_helper'

RSpec.describe 'Captain entry activation', type: :model do
  let(:account) { create(:account) }
  let(:inbox) { create(:inbox, account: account) }
  let(:assistant) do
    create(:captain_assistant, account: account, config: {
             'handoff_message_enabled' => true, 'handoff_message_mode' => 'static', 'handoff_message' => 'Disabled agent message'
           })
  end

  before do
    create(:captain_inbox, inbox: inbox, captain_assistant: assistant)
    inbox.reload
    allow(Captain::Conversation::TypingIndicatorService).to receive(:turn_on)
    allow(Captain::Conversation::TypingIndicatorService).to receive(:turn_off)
  end

  after { Current.reset }

  def receive_customer_message(conversation)
    message = build(:message, account: account, inbox: conversation.inbox, conversation: conversation,
                              sender: conversation.contact, message_type: :incoming)
    message.skip_send_reply = true
    message.save!
  end

  it 'does not assign AI control when a text channel is disabled' do
    inbox.captain_inbox.update!(ai_enabled: false)
    inbox.reload

    conversation = create(:conversation, account: account, inbox: inbox)

    expect(inbox.captain_active?).to be false
    expect(conversation).to be_open
    expect(conversation.ai_pending_handler_present?(fresh_inbox: true)).to be false
    expect(Captain::Conversation::ResponseBuilderJob).not_to receive(:perform_later)
    receive_customer_message(conversation)
  end

  it 'leaves a new incoming conversation open for people when the entry is disabled' do
    assistant.update_columns(active: false)
    inbox.reload
    conversation = create(:conversation, account: account, inbox: inbox)

    expect(inbox.captain_active?).to be false
    expect(conversation).to be_open
    expect(Captain::Conversation::ResponseBuilderJob).not_to receive(:perform_later)

    receive_customer_message(conversation)

    expect(conversation.reload).to be_open
    expect(conversation.ai_pending_handler_present?(fresh_inbox: true)).to be false
    expect(conversation.messages.where(sender: assistant)).to be_empty
  end

  it 'opens an existing pending conversation on incoming activity after a cached entry is disabled' do
    conversation = create(:conversation, account: account, inbox: inbox)
    expect(conversation.inbox.captain_assistant).to be_active
    Captain::Assistant.find(assistant.id).update_columns(active: false)
    expect(Captain::Conversation::ResponseBuilderJob).not_to receive(:perform_later)

    receive_customer_message(conversation)

    expect(conversation.reload).to be_open
    expect(conversation.captain_control_generation).to eq(1)
    expect(conversation.status_transitions.last).to have_attributes(source: 'system', actor_id: nil)
    expect(conversation.messages.where(sender: assistant)).to be_empty
  end

  it 'rejects a new inbox assignment to a disabled entry' do
    assistant.update_columns(active: false)
    assignment = build(:captain_inbox, captain_assistant: assistant, inbox: create(:inbox, account: account))

    expect(assignment).not_to be_valid
    expect(assignment.errors[:captain_assistant]).to include('must be an active external agent')
  end

  it 'keeps existing active internal assignments eligible for legacy operation' do
    assistant.update_columns(usage_mode: 'internal_assistant')
    inbox.reload
    conversation = create(:conversation, account: account, inbox: inbox)

    expect(inbox.captain_active?).to be true
    expect(conversation).to be_pending
    expect(conversation.ai_pending_handler_present?(fresh_inbox: true)).to be true
  end

  context 'with an API inbox that preserves pending status on incoming messages' do
    let(:inbox) { create(:inbox, account: account, channel: build(:channel_api, account: account)) }

    it 'opens the conversation without treating a disabled entry as exhausted quota' do
      conversation = create(:conversation, account: account, inbox: inbox)
      assistant.update_columns(active: false)
      conversation.inbox.reload
      expect(Captain::Conversation::ResponseBuilderJob).not_to receive(:perform_later)

      receive_customer_message(conversation)

      expect(conversation.reload).to be_open
      expect(conversation.status_transitions.last).to have_attributes(source: 'system', actor_id: nil)
      expect(conversation.messages.where(sender: assistant)).to be_empty
      expect(conversation.captain_handoff_applied_at).to be_nil
    end
  end

  context 'with a voice inbox' do
    let(:inbox) do
      allow(Twilio::VoiceWebhookSetupService).to receive(:new)
        .and_return(instance_double(Twilio::VoiceWebhookSetupService, perform: 'APtest'))
      create(:inbox, account: account, channel: build(:channel_voice, account: account))
    end

    it 'keeps the existing voice assignment active independent of the text AI flag' do
      inbox.captain_inbox.update!(ai_enabled: false)

      expect(inbox.reload.captain_active?).to be true
    end
  end
end
