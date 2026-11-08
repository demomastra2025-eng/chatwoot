# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Reminders::IncomingReplyDecisionService do
  let(:account) { create(:account) }
  let(:inbox) { create(:inbox, account: account) }
  let(:contact) { create(:contact, account: account) }
  let(:contact_inbox) { create(:contact_inbox, contact: contact, inbox: inbox) }
  let(:conversation) { create(:conversation, account: account, inbox: inbox, contact: contact, contact_inbox: contact_inbox, status: :pending) }

  describe 'Confirmations::InboundTextResolver AI fallback' do
    let!(:confirmation_request) do
      create(
        :confirmation_request,
        account: account,
        conversation: conversation,
        contact: contact,
        inbox: inbox
      )
    end

    it 'resolves natural-language confirmation ("Буду вовремя, спасибо!") via Decision model when regex is ambiguous' do
      message = create(:message, account: account, inbox: inbox, conversation: conversation,
                                 sender: contact, message_type: :incoming, content: 'Буду вовремя, спасибо!')

      expect(Llm::Runtime).to receive(:decide).with(
        hash_including(feature: :outbound_reply_classification, account: account)
      ).and_return(
        Llm::OpenRouterDecisionClient::Result.new(
          choice: 'confirm_appointment',
          confidence: 0.94,
          model: 'perplexity/pplx-decider-flash-v1.2'
        )
      )

      result = Confirmations::InboundTextResolver.new(
        account: account,
        conversation: conversation,
        message: message
      ).perform

      expect(result).to include(handled: true, decision: 'confirmed')
      expect(confirmation_request.reload).to be_confirmed
      expect(confirmation_request.resolution_source).to eq('ai')
    end
  end

  describe 'Reminders::AutoCancelOnIncomingService integration' do
    it 'automatically marks a single scheduled appointment as confirmed when reply is confirm_appointment' do
      appointment = create(
        :scheduling_appointment,
        account: account,
        contact: contact,
        conversation: conversation,
        status: 'scheduled',
        starts_at: 1.day.from_now,
        ends_at: 1.day.from_now + 30.minutes
      )
      touch = create(
        :reminder,
        account: account,
        conversation: conversation,
        remindable: appointment,
        status: :pending,
        auto_cancel_on_incoming: true,
        metadata: { 'auto_cancel_on_incoming_explicit' => true },
        created_at: 5.minutes.ago
      )
      message = create(:message, account: account, inbox: inbox, conversation: conversation,
                                 sender: contact, message_type: :incoming, content: 'Обязательно подойдем к 10 утра')

      expect(Llm::Runtime).to receive(:decide).with(
        hash_including(feature: :outbound_reply_classification, account: account)
      ).and_return(
        Llm::OpenRouterDecisionClient::Result.new(
          choice: 'confirm_appointment',
          confidence: 0.93,
          model: 'perplexity/pplx-decider-flash-v1.2'
        )
      )

      Reminders::AutoCancelOnIncomingService.new(message: message).perform

      expect(touch.reload).to be_cancelled
      expect(appointment.reload.status).to eq('confirmed')
      expect(appointment.custom_attributes['confirmed_via_decision_ai_at']).to be_present
    end

    it 'marks contact outbound_opt_out and suppresses Captain auto-reply on stop_or_negative' do
      touch = create(
        :reminder,
        account: account,
        conversation: conversation,
        remindable: conversation,
        status: :pending,
        auto_cancel_on_incoming: true,
        metadata: { 'auto_cancel_on_incoming_explicit' => true },
        created_at: 5.minutes.ago
      )
      message = create(:message, account: account, inbox: inbox, conversation: conversation,
                                 sender: contact, message_type: :incoming, content: 'Не пишите мне больше, удалите мой номер!')

      expect(Llm::Runtime).to receive(:decide).with(
        hash_including(feature: :outbound_reply_classification, account: account)
      ).and_return(
        Llm::OpenRouterDecisionClient::Result.new(
          choice: 'stop_or_negative',
          confidence: 0.97,
          model: 'perplexity/pplx-decider-flash-v1.2'
        )
      )

      Reminders::AutoCancelOnIncomingService.new(message: message).perform

      expect(touch.reload).to be_cancelled
      expect(contact.reload.custom_attributes['outbound_opt_out']).to be(true)
      expect(message.reload.content_attributes['suppress_captain_auto_reply']).to be(true)
      expect(message.content_attributes['outbound_reply_decision']).to eq('stop_or_negative')
    end
  end
end
