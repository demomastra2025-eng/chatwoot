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

  describe 'the end of a call in a thread with another open dialog' do
    let(:whatsapp_inbox) { create(:channel_whatsapp_web, account: account).inbox }

    before { account.enable_features!('communication_threads') }

    def open_dialog(inbox, minutes_ago:, attributes: {})
      create(:conversation, account: account, inbox: inbox, contact: contact, status: :resolved).tap do |record|
        record.update_columns( # rubocop:disable Rails/SkipsModelValidations
          { status: Conversation.statuses.fetch('open'), last_activity_at: minutes_ago.minutes.ago }.merge(attributes)
        )
      end
    end

    def call_session_for(record, status:, answered_at: nil)
      Telephony::CallSession.create!(
        account: account, inbox: voice_inbox, contact: contact, conversation: record, provider: 'wazo',
        external_call_ref: "wazo-#{SecureRandom.hex(4)}", direction: 'inbound', status: status, answered_at: answered_at,
        from_number: '+77015556677', to_number: '+77085012233', ended_at: Time.current
      )
    end

    it 'decides the single open dialog once an answered call is over, because no conversation was closed during it', :aggregate_failures do
      chat = open_dialog(whatsapp_inbox, minutes_ago: 5)
      call = open_dialog(voice_inbox, minutes_ago: 0, attributes: { additional_attributes: { 'call_status' => 'completed' } })
      session = call_session_for(call, status: 'completed', answered_at: 2.minutes.ago)

      expect(described_class.sync_for_call_session!(session)).to eq(:callback_cleared)

      expect(chat.reload).to be_open
      expect(call.reload).to be_resolved
    end

    it 'carries a missed call to the dialog that stays, and leaves the flag on the resolved call', :aggregate_failures do
      chat = open_dialog(whatsapp_inbox, minutes_ago: 5)
      call = open_dialog(voice_inbox, minutes_ago: 0, attributes: { additional_attributes: { 'call_status' => 'no_answer' } })
      session = call_session_for(call, status: 'no_answer')

      expect(described_class.sync_for_call_session!(session)).to eq(:missed_marked)

      expect(chat.reload).to be_open
      expect(described_class.waiting_for_callback?(chat)).to be(true)
      expect(chat.additional_attributes['last_missed_call_ref']).to eq(session.external_call_ref)
      expect(call.reload).to be_resolved
      expect(described_class.waiting_for_callback?(call)).to be(true)
    end

    # The intake of a call runs every step in a savepoint of the transaction under the intake lock. The refresh of the thread
    # holds the contact advisory lock until that transaction ends, so the merge must not lock the chat rows meanwhile: a
    # message of the same person locks its chat first and the advisory lock second, which would deadlock with it.
    it 'merges after the transaction of the call intake, not inside it', :aggregate_failures do
      chat = open_dialog(whatsapp_inbox, minutes_ago: 5)
      call = open_dialog(voice_inbox, minutes_ago: 0, attributes: { additional_attributes: { 'call_status' => 'no_answer' } })
      session = call_session_for(call, status: 'no_answer')
      inside_intake = nil
      row_locks_after_advisory = nil
      statements = []
      subscription = ActiveSupport::Notifications.subscribe('sql.active_record') { |*, payload| statements << payload[:sql] }

      ActiveRecord::Base.transaction do
        Telephony::CallSession.transaction(requires_new: true) do
          expect(described_class.sync_for_call_session!(session)).to eq(:missed_marked)
        end
        advisory = statements.index { |sql| sql.include?('pg_advisory_xact_lock') }
        row_locks_after_advisory = statements.drop(advisory).grep(/FOR UPDATE/i)
        inside_intake = [chat.reload.status, call.reload.status]
      end

      expect(row_locks_after_advisory).to be_empty
      expect(inside_intake).to eq(%w[open open])
      expect([chat.reload.status, call.reload.status]).to eq(%w[open resolved])
      expect(described_class.waiting_for_callback?(chat)).to be(true)
      expect(chat.additional_attributes['last_missed_call_ref']).to eq(session.external_call_ref)
    ensure
      ActiveSupport::Notifications.unsubscribe(subscription)
    end

    it 'does not close anything while the call has not ended' do
      chat = open_dialog(whatsapp_inbox, minutes_ago: 5)
      call = open_dialog(voice_inbox, minutes_ago: 0, attributes: { additional_attributes: { 'call_status' => 'in_progress' } })
      session = call_session_for(call, status: 'in_progress', answered_at: Time.current)

      described_class.sync_for_call_session!(session)

      expect([chat.reload.status, call.reload.status]).to eq(%w[open open])
    end
  end
end
