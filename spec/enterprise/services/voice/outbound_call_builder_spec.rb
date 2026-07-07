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

    context 'with native SIP provider' do
      let(:channel) { create(:channel_voice, :sipuni, account: account, phone_number: '+15551230000') }
      let(:call_sid) { 'sipuni-new-outbound-call-1' }
      let!(:contact_inbox) { create(:contact_inbox, contact: contact, inbox: inbox, source_id: contact.phone_number) }
      let!(:existing_conversation) do
        create(
          :conversation,
          account: account,
          inbox: inbox,
          contact: contact,
          contact_inbox: contact_inbox,
          status: :resolved,
          identifier: 'sipuni-previous-call',
          additional_attributes: {
            'call_direction' => 'outbound',
            'call_status' => 'completed',
            'telephony_call_ref' => 'sipuni-previous-call',
            'call_started_at' => 100,
            'call_ended_at' => 120,
            'call_duration' => 20,
            'recording_ref' => 'old-recording.wav',
            'recording' => { 'storage_key' => 'old-recording.wav' },
            'from_number' => '+15559990000',
            'to_number' => '+15550000000'
          }
        )
      end
      let!(:call_session) do
        create(
          :telephony_call_session,
          account: account,
          conversation: existing_conversation,
          contact: contact,
          inbox: inbox,
          number_binding: inbox.telephony_number_binding,
          external_call_ref: call_sid,
          provider: 'sipuni',
          status: 'ringing',
          direction: 'outbound'
        )
      end
      let(:calls_service) { instance_double(Telephony::CallsService) }

      before do
        create(
          :message,
          account: account,
          inbox: inbox,
          conversation: existing_conversation,
          message_type: :outgoing,
          content_type: :voice_call,
          sender: user,
          source_id: 'voice_call:sipuni-previous-call',
          content_attributes: { 'data' => { 'call_sid' => 'sipuni-previous-call', 'status' => 'completed' } }
        )
        allow(Telephony::CallsService).to receive(:new).with(account: account).and_return(calls_service)
        allow(calls_service).to receive(:create_outbound!).and_return(
          call_ref: call_sid,
          status: 'ringing',
          call_session: call_session
        )
      end

      it 'reuses the latest open contact conversation without replacing previous call history' do
        expect do
          described_class.perform!(account: account, inbox: inbox, user: user, contact: contact)
        end.not_to(change { account.conversations.where(inbox_id: inbox.id, contact_id: contact.id).count })

        expect(calls_service).to have_received(:create_outbound!).with(
          inbox: inbox,
          contact: contact,
          user: user,
          conversation: existing_conversation
        )

        existing_conversation.reload
        voice_messages = existing_conversation.messages.voice_calls.order(:created_at, :id)

        aggregate_failures do
          expect(existing_conversation.identifier).to eq('sipuni-previous-call')
          expect(existing_conversation).to be_open
          expect(existing_conversation.additional_attributes).to include(
            'call_direction' => 'outbound',
            'call_status' => 'ringing',
            'telephony_call_ref' => call_sid,
            'from_number' => channel.phone_number,
            'to_number' => contact.phone_number
          )
          expect(existing_conversation.additional_attributes).not_to have_key('call_started_at')
          expect(existing_conversation.additional_attributes).not_to have_key('call_ended_at')
          expect(existing_conversation.additional_attributes).not_to have_key('call_duration')
          expect(existing_conversation.additional_attributes).not_to have_key('recording_ref')
          expect(existing_conversation.additional_attributes).not_to have_key('recording')
          expect(voice_messages.count).to eq(2)
          expect(voice_messages.last.source_id).to eq("voice_call:#{call_sid}")
          expect(voice_messages.first.content_attributes.dig('data', 'call_sid')).to eq('sipuni-previous-call')
        end
      end
    end
  end
end
