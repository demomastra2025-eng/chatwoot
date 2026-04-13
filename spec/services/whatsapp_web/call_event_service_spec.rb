require 'rails_helper'

RSpec.describe WhatsappWeb::CallEventService do
  around do |example|
    with_modified_env(
      'EVOLUTION_API_URL' => 'https://evolution.example.com',
      'EVOLUTION_API_KEY' => 'test-api-key',
      'FRONTEND_URL' => 'https://app.example.com'
    ) do
      example.run
    end
  end

  let(:channel) { create(:channel_whatsapp_web) }

  describe '#perform' do
    it 'creates a voice_call message for inbound offer events' do
      conversation = described_class.new(
        channel: channel,
        payload: {
          id: 'call-1',
          from: '15551234567@s.whatsapp.net',
          status: 'offer',
          isVideo: true,
          timestamp: 1_717_171_717
        }
      ).perform

      voice_message = conversation.messages.voice_calls.last

      expect(voice_message).to be_present
      expect(voice_message.message_type).to eq('incoming')
      expect(voice_message.sender).to eq(conversation.contact)
      expect(voice_message.source_id).to eq('call-1')
      expect(conversation.additional_attributes['call_status']).to eq('ringing')
      expect(conversation.additional_attributes['call_direction']).to eq('inbound')
      expect(voice_message.content_attributes['data']).to include(
        'call_sid' => 'call-1',
        'status' => 'ringing',
        'call_direction' => 'inbound',
        'provider' => 'whatsapp_web',
        'inbox_id' => channel.inbox.id,
        'remote_jid' => '15551234567@s.whatsapp.net',
        'is_video' => true
      )
    end

    it 'updates the existing voice_call message for later call statuses' do
      described_class.new(
        channel: channel,
        payload: {
          id: 'call-2',
          from: '15559876543@s.whatsapp.net',
          status: 'offer',
          timestamp: 1_717_171_717
        }
      ).perform

      conversation = channel.inbox.conversations.last

      expect do
        described_class.new(
          channel: channel,
          payload: {
            id: 'call-2',
            from: '15559876543@s.whatsapp.net',
            status: 'completed',
            duration: 42,
            timestamp: 1_717_171_777
          }
        ).perform
      end.not_to change { conversation.reload.messages.voice_calls.count }

      voice_message = conversation.reload.messages.voice_calls.last
      expect(conversation.additional_attributes['call_status']).to eq('completed')
      expect(conversation.additional_attributes['call_duration']).to eq(42)
      expect(voice_message.content_attributes.dig('data', 'status')).to eq('completed')
      expect(voice_message.content_attributes.dig('data', 'meta', 'duration')).to eq(42)
      expect(voice_message.content_attributes.dig('data', 'meta', 'ended_at')).to eq(1_717_171_777)
    end

    it 'ignores unsupported raw transport callback payloads' do
      expect do
        described_class.new(
          channel: channel,
          payload: {
            event: 'CB:call',
            packet: {
              attrs: { id: 'raw-1' }
            }
          }
        ).perform
      end.not_to change { channel.inbox.messages.count }
    end
  end
end
