# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Confirmations::TelegramReplyResolver do
  let(:account) { create(:account) }
  let(:conversation) { create(:conversation, account: account) }
  let(:confirmation_request) do
    create(
      :confirmation_request,
      account: account,
      conversation: conversation,
      contact: conversation.contact,
      inbox: conversation.inbox
    )
  end

  it 'resolves a signed Telegram callback with the contact actor and Telegram source' do
    callback_value = Confirmations::TelegramCallback.encode(confirmation_request, 'confirmed')
    terminal_feedback = instance_double(Confirmations::TelegramTerminalFeedbackService, perform: true)
    expect(Confirmations::TelegramTerminalFeedbackService).to receive(:new)
      .with(confirmation_request: confirmation_request)
      .and_return(terminal_feedback)

    result = described_class.new(
      conversation: conversation,
      actor: conversation.contact,
      inbox: conversation.inbox,
      callback_value: callback_value,
      callback_query_id: 'callback-123'
    ).perform

    expect(result).to eq(confirmation_request)
    expect(confirmation_request.reload).to be_confirmed
    expect(confirmation_request.resolved_by).to be_nil
    expect(confirmation_request.resolution_source).to eq('button')
    expect(confirmation_request.resolution_metadata).to include(
      'channel' => 'telegram',
      'telegram_callback_query_id' => 'callback-123',
      'resolver_actor_type' => 'Contact',
      'resolver_actor_id' => conversation.contact.id
    )
  end

  it 'rejects a tampered callback without changing the request' do
    callback_value = Confirmations::TelegramCallback.encode(confirmation_request, 'declined')
    tampered_value = callback_value.sub(/\z/, callback_value.end_with?('a') ? 'b' : 'a')

    expect(
      described_class.new(
        conversation: conversation,
        actor: conversation.contact,
        inbox: conversation.inbox,
        callback_value: tampered_value
      ).perform
    ).to be_nil
    expect(confirmation_request.reload).to be_pending
  end

  it 'fails closed when the signed callback targets an expired request' do
    callback_value = Confirmations::TelegramCallback.encode(confirmation_request, 'confirmed')
    confirmation_request.update!(expires_at: 1.minute.ago)

    result = described_class.new(
      conversation: conversation,
      actor: conversation.contact,
      inbox: conversation.inbox,
      callback_value: callback_value
    ).perform

    expect(result).to be_nil
    expect(confirmation_request.reload).to be_expired
  end

  it 'fails closed when the signed callback conflicts with an existing decision' do
    callback_value = Confirmations::TelegramCallback.encode(confirmation_request, 'declined')
    confirmation_request.update!(status: 'confirmed', resolved_at: Time.current, resolution_source: 'manual')

    result = described_class.new(
      conversation: conversation,
      actor: conversation.contact,
      inbox: conversation.inbox,
      callback_value: callback_value
    ).perform

    expect(result).to be_nil
    expect(confirmation_request.reload).to be_confirmed
  end
end
