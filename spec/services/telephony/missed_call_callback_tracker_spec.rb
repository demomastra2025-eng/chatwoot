# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Telephony::MissedCallCallbackTracker do
  let(:account) { create(:account) }
  let(:voice_channel) do
    create(
      :channel_voice,
      account: account,
      provider: 'wazo',
      phone_number: '+77085012233',
      provider_config: {
        'provider_kind' => 'wazo',
        'number_ref' => 'wazo-num-1',
        'provider_connection_id' => 1
      }
    )
  end
  let(:voice_inbox) { voice_channel.inbox }
  let(:contact) { create(:contact, account: account, phone_number: '+77015556677') }
  let(:contact_inbox) { create(:contact_inbox, contact: contact, inbox: voice_inbox, source_id: '+77015556677') }
  let(:conversation) do
    create(
      :conversation,
      account: account,
      inbox: voice_inbox,
      contact: contact,
      contact_inbox: contact_inbox
    )
  end

  describe '.sync_for_call_session! and .clear_on_outgoing_message!' do
    it 'marks conversation as waiting_for_callback on unanswered inbound terminal call and clears it when an outbound call is answered' do
      missed_session = Telephony::CallSession.create!(
        account: account,
        inbox: voice_inbox,
        contact: contact,
        conversation: conversation,
        provider: 'wazo',
        external_call_ref: 'wazo-inbound-missed-1',
        direction: 'inbound',
        status: 'no_answer',
        from_number: '+77015556677',
        to_number: '+77085012233',
        ended_at: Time.current
      )
      voice_msg = conversation.messages.create!(
        account: account,
        inbox: voice_inbox,
        message_type: :incoming,
        content: 'Voice Call',
        content_type: :voice_call,
        source_id: missed_session.voice_call_source_id,
        content_attributes: {
          'data' => {
            'call_sid' => missed_session.external_call_ref,
            'status' => 'no_answer',
            'call_direction' => 'inbound',
            'waiting_for_callback' => true
          }
        }
      )

      result = described_class.sync_for_call_session!(missed_session)

      expect(result).to eq(:missed_marked)
      expect(described_class.waiting_for_callback?(conversation.reload)).to be(true)
      expect(conversation.custom_attributes['waiting_for_callback']).to be(true)
      expect(conversation.additional_attributes['waiting_for_callback']).to be(true)
      expect(conversation.additional_attributes['last_missed_call_ref']).to eq('wazo-inbound-missed-1')

      # Now operator calls back and the customer answers
      callback_session = Telephony::CallSession.create!(
        account: account,
        inbox: voice_inbox,
        contact: contact,
        conversation: conversation,
        provider: 'wazo',
        external_call_ref: 'wazo-outbound-callback-1',
        direction: 'outbound',
        status: 'in_progress',
        from_number: '+77085012233',
        to_number: '+77015556677',
        answered_at: Time.current
      )

      clear_result = described_class.sync_for_call_session!(callback_session)

      expect(clear_result).to eq(:callback_cleared)
      expect(described_class.waiting_for_callback?(conversation.reload)).to be(false)
      expect(voice_msg.reload.content_attributes.dig('data', 'waiting_for_callback')).to be(false)
    end

    it 'does not mark waiting_for_callback when a sibling leg was closed because another operator answered' do
      sibling_leg = Telephony::CallSession.create!(
        account: account,
        inbox: voice_inbox,
        contact: contact,
        conversation: conversation,
        provider: 'wazo',
        external_call_ref: 'wazo-inbound-sibling-1',
        direction: 'inbound',
        status: 'cancelled',
        end_reason: Telephony::SiblingLegCloser::END_REASON,
        from_number: '+77015556677',
        to_number: '+77085012233',
        ended_at: Time.current
      )

      result = described_class.sync_for_call_session!(sibling_leg)

      expect(result).to eq(:noop)
      expect(described_class.waiting_for_callback?(conversation.reload)).to be(false)
    end

    it 'clears waiting_for_callback across all conversations of the contact when an operator sends a non-private outgoing message, but ignores private notes and auto-followup messages' do
      conversation.update!(
        custom_attributes: { 'waiting_for_callback' => true },
        additional_attributes: { 'waiting_for_callback' => true }
      )

      # Private note should NOT clear waiting_for_callback
      private_note = conversation.messages.create!(
        account: account,
        inbox: voice_inbox,
        message_type: :outgoing,
        private: true,
        content: 'Internal note'
      )
      expect(described_class.clear_on_outgoing_message!(private_note)).to be(false)
      expect(described_class.waiting_for_callback?(conversation.reload)).to be(true)

      # Automated WhatsApp follow-up message should NOT clear waiting_for_callback
      auto_followup = conversation.messages.create!(
        account: account,
        inbox: voice_inbox,
        message_type: :outgoing,
        private: false,
        content: 'Мы пропустили ваш звонок',
        additional_attributes: { 'missed_call_whatsapp_followup' => true },
        skip_send_reply: true
      )
      expect(described_class.clear_on_outgoing_message!(auto_followup)).to be(false)
      expect(described_class.waiting_for_callback?(conversation.reload)).to be(true)

      # Real operator reply in a sibling conversation of the same contact clears waiting_for_callback
      other_inbox = create(:inbox, account: account)
      other_contact_inbox = create(:contact_inbox, contact: contact, inbox: other_inbox)
      sibling_conversation = create(
        :conversation,
        account: account,
        inbox: other_inbox,
        contact: contact,
        contact_inbox: other_contact_inbox
      )
      operator_reply = sibling_conversation.messages.create!(
        account: account,
        inbox: other_inbox,
        message_type: :outgoing,
        private: false,
        content: 'Здравствуйте! Перезванивали вам, чем помочь?',
        skip_send_reply: true
      )

      expect(described_class.waiting_for_callback?(conversation.reload)).to be(false)
      expect(operator_reply).to be_persisted
    end

    it 'filters conversations by waiting_for_callback in ConversationFinder without extra JOINs' do
      admin = create(:user, account: account, role: :administrator)
      other_contact = create(:contact, account: account, phone_number: '+77019990000')
      other_ci = create(:contact_inbox, contact: other_contact, inbox: voice_inbox)
      normal_conversation = create(
        :conversation,
        account: account,
        inbox: voice_inbox,
        contact: other_contact,
        contact_inbox: other_ci
      )

      conversation.update!(
        custom_attributes: { 'waiting_for_callback' => true },
        additional_attributes: { 'waiting_for_callback' => true }
      )

      result = ConversationFinder.new(
        admin,
        ActionController::Parameters.new(status: 'open', waiting_for_callback: 'true'),
        account
      ).perform

      expect(result[:conversations].map(&:id)).to eq([conversation.id])
      expect(result[:conversations].map(&:id)).not_to include(normal_conversation.id)
    end
  end
end
