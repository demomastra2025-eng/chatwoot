# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Voice::OutboundCallBuilder do
  let(:account) { create(:account) }
  let(:channel) { create(:channel_voice, account: account, phone_number: '+15551230000') }
  let(:inbox) { channel.inbox }
  let(:user) { create(:user, account: account) }
  let(:contact) { create(:contact, account: account, phone_number: '+15550001111') }
  let(:call_sid) { 'CA1234567890abcdef' }

  before do
    allow(Twilio::VoiceWebhookSetupService).to receive(:new)
      .and_return(instance_double(Twilio::VoiceWebhookSetupService, perform: "AP#{SecureRandom.hex(8)}"))
    allow(inbox).to receive(:channel).and_return(channel)
    allow(channel).to receive(:initiate_call).and_return({ call_sid: call_sid })
    allow(Voice::Conference::Name).to receive(:for).and_call_original
  end

  describe '.perform!' do
    it 'creates a conversation and voice call message' do
      conversation_count = account.conversations.count
      inbox_link_count = contact.contact_inboxes.where(inbox_id: inbox.id).count

      result = described_class.perform!(
        account: account,
        inbox: inbox,
        user: user,
        contact: contact
      )

      expect(account.conversations.count).to eq(conversation_count + 1)
      expect(contact.contact_inboxes.where(inbox_id: inbox.id).count).to eq(inbox_link_count + 1)

      conversation = result[:conversation].reload
      attrs = conversation.additional_attributes

      aggregate_failures do
        expect(result[:call_sid]).to eq(call_sid)
        expect(conversation.identifier).to eq(call_sid)
        expect(attrs).to include('call_direction' => 'outbound', 'call_status' => 'ringing')
        expect(attrs['agent_id']).to eq(user.id)
        expect(attrs['conference_sid']).to be_present

        voice_message = conversation.messages.voice_calls.last
        expect(voice_message.message_type).to eq('outgoing')

        message_data = voice_message.content_attributes['data']
        expect(message_data).to include(
          'call_sid' => call_sid,
          'conference_sid' => attrs['conference_sid'],
          'from_number' => channel.phone_number,
          'to_number' => contact.phone_number
        )
      end
    end

    it 'raises an error when contact is missing a phone number' do
      contact.update!(phone_number: nil)

      expect do
        described_class.perform!(
          account: account,
          inbox: inbox,
          user: user,
          contact: contact
        )
      end.to raise_error(ArgumentError, 'Contact phone number required')
    end

    it 'raises an error when user is nil' do
      expect do
        described_class.perform!(
          account: account,
          inbox: inbox,
          user: nil,
          contact: contact
        )
      end.to raise_error(ArgumentError, 'Agent required')
    end

    it 'ensures the conversation has a display_id before building the conference SID' do
      allow(Voice::Conference::Name).to receive(:for).and_wrap_original do |original, conversation|
        expect(conversation.display_id).to be_present
        original.call(conversation)
      end

      described_class.perform!(
        account: account,
        inbox: inbox,
        user: user,
        contact: contact
      )
    end

    context 'with Sipuni outbound callback identity' do
      let(:channel) { create(:channel_voice, :sipuni, account: account, phone_number: '+77271234567') }
      let(:contact) { create(:contact, account: account, phone_number: '+77015550102') }
      let(:agent_binding) do
        create(
          :telephony_agent_binding,
          account: account,
          user: user,
          provider: 'sipuni',
          agent_ref: 'sipuni-agent-100',
          agent_aor: 'sip:100@sipuni.example'
        )
      end

      before do
        agent_binding
        allow(SendReplyJob).to receive(:perform_later).and_return(true)
      end

      it 'treats the Sipuni callback order id as initiation metadata and reconciles webhook call_id as canonical' do
        allow(channel).to receive(:initiate_call).and_return(
          provider: 'sipuni',
          call_sid: 'sipuni-callback-order-1',
          provider_request_ref: 'sipuni-callback-order-1',
          status: 'ringing',
          sipuni_response: { 'callbackId' => 'sipuni-callback-order-1', 'status' => 'ringing' }
        )

        result = described_class.perform!(account: account, inbox: inbox, user: user, contact: contact)
        conversation = result[:conversation]

        described_class_payload('sipuni-webhook-call-1').then do |payload|
          Telephony::EventsIngestionService.new(payload: payload).perform
        end

        call_session = account.telephony_call_sessions.find_by!(external_call_ref: 'sipuni-webhook-call-1')
        conversation.reload
        voice_messages = conversation.messages.voice_calls

        aggregate_failures do
          expect(account.conversations.where(inbox_id: inbox.id, contact_id: contact.id).count).to eq(1)
          expect(call_session.conversation_id).to eq(conversation.id)
          expect(conversation.identifier).to eq('sipuni-webhook-call-1')
          expect(conversation.additional_attributes.dig('meta', 'provider_request_ref')).to eq('sipuni-callback-order-1')
          expect(call_session.metadata.dig('sipuni_outbound_initiation', 'provider_request_ref')).to eq('sipuni-callback-order-1')
          expect(voice_messages.count).to eq(1)
          expect(voice_messages.first.source_id).to eq('voice_call:sipuni-webhook-call-1')
          expect(voice_messages.first.content_attributes.dig('data', 'call_sid')).to eq('sipuni-webhook-call-1')
          expect(voice_messages.first.content_attributes.dig('data', 'status')).to eq('no_answer')
        end
      end

      it 'reuses the pending outbound conversation when the Sipuni webhook arrives before callback response handling finishes' do
        allow(channel).to receive(:initiate_call) do
          Telephony::EventsIngestionService.new(payload: described_class_payload('sipuni-webhook-race-1')).perform
          {
            provider: 'sipuni',
            call_sid: 'sipuni-callback-order-race-1',
            provider_request_ref: 'sipuni-callback-order-race-1',
            status: 'ringing',
            sipuni_response: { 'callbackId' => 'sipuni-callback-order-race-1', 'status' => 'ringing' }
          }
        end

        result = described_class.perform!(account: account, inbox: inbox, user: user, contact: contact)
        conversation = result[:conversation].reload
        call_session = account.telephony_call_sessions.find_by!(external_call_ref: 'sipuni-webhook-race-1')
        voice_messages = conversation.messages.voice_calls

        aggregate_failures do
          expect(account.conversations.where(inbox_id: inbox.id, contact_id: contact.id).count).to eq(1)
          expect(account.telephony_call_sessions.where(external_call_ref: 'sipuni-webhook-race-1').count).to eq(1)
          expect(call_session.conversation_id).to eq(conversation.id)
          expect(conversation.identifier).to eq('sipuni-webhook-race-1')
          expect(conversation.additional_attributes['call_status']).to eq('no_answer')
          expect(conversation.additional_attributes.dig('meta', 'provider_request_ref')).to eq('sipuni-callback-order-race-1')
          expect(voice_messages.count).to eq(1)
          expect(voice_messages.first.source_id).to eq('voice_call:sipuni-webhook-race-1')
          expect(voice_messages.first.content_attributes.dig('data', 'status')).to eq('no_answer')
        end
      end

      it 'removes the pending Sipuni conversation when callback initiation fails before any webhook links the call' do
        allow(channel).to receive(:initiate_call).and_raise(
          Telephony::Error.new(code: 'SIPUNI_OUTBOUND_FAILED', message: 'Sipuni rejected outbound callback request', status: :bad_gateway)
        )

        expect do
          described_class.perform!(account: account, inbox: inbox, user: user, contact: contact)
        end.to raise_error(Telephony::Error, /Sipuni rejected outbound callback request/)

        expect(account.conversations.where(inbox_id: inbox.id, contact_id: contact.id)).to be_empty
      end

      def described_class_payload(call_ref)
        ended_at = Time.current
        started_at = ended_at - 30.seconds

        {
          provider: 'sipuni',
          event: 'dial_status',
          status: 'no_answer',
          event_key: "evt-#{call_ref}",
          call_ref: call_ref,
          account_id: account.id,
          inbox_id: inbox.id,
          direction: 'outbound',
          from_number: channel.phone_number,
          to_number: contact.phone_number,
          agent_ref: agent_binding.agent_ref,
          occurred_at: ended_at.iso8601,
          started_at: started_at.iso8601,
          ended_at: ended_at.iso8601,
          ended_by: 'callee',
          end_reason: 'noanswer',
          duration: 0,
          metadata: {
            provider: 'sipuni',
            operator_internal_number: '100'
          }
        }
      end
    end
  end
end
