require 'rails_helper'

RSpec.describe Reminders::AutoCancelOnIncomingService do
  let(:account) { create(:account) }
  let(:inbox) { create(:inbox, account: account) }
  let(:contact) { create(:contact, account: account) }
  let(:contact_inbox) { create(:contact_inbox, contact: contact, inbox: inbox) }
  let(:conversation) do
    create(:conversation, account: account, inbox: inbox, contact: contact, contact_inbox: contact_inbox)
  end

  def incoming_message
    create(
      :message,
      account: account,
      inbox: inbox,
      conversation: conversation,
      sender: contact,
      message_type: :incoming,
      private: false
    )
  end

  it 'cancels open auto-cancel touches after an incoming customer reply' do
    touch = create(
      :reminder,
      account: account,
      conversation: conversation,
      remindable: conversation,
      status: :pending,
      auto_cancel_on_incoming: true,
      metadata: { 'auto_cancel_on_incoming_explicit' => true }
    )
    incoming_message

    described_class.new(message: conversation.messages.incoming.last).perform

    expect(touch.reload).to be_cancelled
    expect(touch.last_error).to eq(Reminders::AutoCancelOnIncomingService::CANCELLED_AFTER_INCOMING_REPLY)
  end

  it 'clears processing_started_at when cancelling a touch that was being processed' do
    touch = create(
      :reminder,
      account: account,
      conversation: conversation,
      remindable: conversation,
      status: :processing,
      processing_started_at: 10.minutes.ago,
      auto_cancel_on_incoming: true,
      metadata: { 'auto_cancel_on_incoming_explicit' => true }
    )
    incoming_message

    described_class.new(message: conversation.messages.incoming.last).perform

    expect(touch.reload).to be_cancelled
    expect(touch.processing_started_at).to be_nil
  end

  it 'does not cancel a processing touch after its outgoing message was materialized' do
    touch = create(
      :reminder,
      account: account,
      conversation: conversation,
      remindable: conversation,
      status: :pending,
      processing_started_at: nil,
      auto_cancel_on_incoming: true,
      metadata: { 'auto_cancel_on_incoming_explicit' => true }
    )
    touch.mark_processing!
    touch.mark_delivery_materialized!(123)
    incoming_message

    described_class.new(message: conversation.messages.incoming.last).perform

    expect(touch.reload).to be_processing
    expect(touch.processing_started_at).to be_present
  end

  it 'does not cancel touches without explicit auto-cancel opt-in' do
    touch = create(
      :reminder,
      account: account,
      conversation: conversation,
      remindable: conversation,
      status: :pending,
      auto_cancel_on_incoming: true
    )
    incoming_message

    described_class.new(message: conversation.messages.incoming.last).perform

    expect(touch.reload).not_to be_cancelled
  end
end
