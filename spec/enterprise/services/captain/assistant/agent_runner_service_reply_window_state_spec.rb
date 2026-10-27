# frozen_string_literal: true

require 'rails_helper'

# What the agent is told about the WhatsApp reply window is the window of the customer's number, the same one the delivery
# policy and the reply box use (Conversations::MessageWindowService), not the window of the one conversation it is answering in.
RSpec.describe Captain::Assistant::AgentRunnerService, '#reply_window_state' do
  let(:account) { create(:account) }
  let(:whatsapp_inbox) { create(:channel_whatsapp, account: account, sync_templates: false, validate_provider_config: false).inbox }
  let(:contact) { create(:contact, account: account) }
  let(:customer_number) { create(:contact_inbox, contact: contact, inbox: whatsapp_inbox) }
  let(:assistant) { create(:captain_assistant, account: account) }

  before { allow(Llm::Config).to receive(:initialize!) }

  def conversation_on(contact_inbox)
    create(:conversation, account: account, inbox: whatsapp_inbox, contact: contact, contact_inbox: contact_inbox)
  end

  def state_of(conversation)
    described_class.new(assistant: assistant, conversation: conversation).send(:reply_window_state)
  end

  it 'is open for a conversation the staff started when the customer wrote from the same number in another one' do
    earlier = conversation_on(customer_number)
    started_by_staff = conversation_on(customer_number)
    create(:message, account: account, inbox: whatsapp_inbox, conversation: earlier, message_type: :incoming, created_at: 10.minutes.ago)

    expect(state_of(started_by_staff)).to include(channel: 'official_whatsapp', open_now: true)
  end

  it 'is not opened by a message from another number of the same person' do
    earlier = conversation_on(customer_number)
    on_other_number = conversation_on(create(:contact_inbox, contact: contact, inbox: whatsapp_inbox))
    create(:message, account: account, inbox: whatsapp_inbox, conversation: earlier, message_type: :incoming, created_at: 10.minutes.ago)

    expect(state_of(on_other_number)).to include(channel: 'official_whatsapp', open_now: false)
  end
end
