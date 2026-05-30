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

  def perform_call_event(id:, from:, status:, timestamp:, **attributes)
    described_class.new(
      channel: channel,
      payload: { id: id, from: from, status: status, timestamp: timestamp }.merge(attributes)
    ).perform
  end

  def expected_inbound_call_payload(call_id, remote_jid, status: 'completed', is_video: false)
    {
      'call_sid' => call_id,
      'status' => status,
      'call_direction' => 'inbound',
      'provider' => 'whatsapp_web',
      'inbox_id' => channel.inbox.id,
      'remote_jid' => remote_jid,
      'is_video' => is_video
    }
  end

  def sole_voice_call_data(conversation)
    conversation.reload.messages.voice_calls.sole.content_attributes['data']
  end

  def expect_ordered_timestamps(payload, *keys)
    values = payload.values_at(*keys)

    expect(values).to eq(values.sort)
  end

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
      end.not_to(change { conversation.reload.messages.voice_calls.count })

      voice_message = conversation.reload.messages.voice_calls.last
      expect(conversation.additional_attributes['call_status']).to eq('completed')
      expect(conversation.additional_attributes['call_duration']).to eq(42)
      expect(voice_message.content_attributes.dig('data', 'status')).to eq('completed')
      expect(voice_message.content_attributes.dig('data', 'meta', 'duration')).to eq(42)
      expect(voice_message.content_attributes.dig('data', 'meta', 'ended_at')).to eq(1_717_171_777)
    end

    it 'records one answered inbound caller-hangup terminal event with ordered payload fields' do
      call_id = 'call-answered-drop'
      remote_jid = '15550001111@s.whatsapp.net'
      perform_call_event(id: call_id, from: remote_jid, status: 'offer', isVideo: false, timestamp: 1_717_171_700)
      conversation = channel.inbox.conversations.last
      perform_call_event(id: call_id, from: remote_jid, status: 'accept', timestamp: 1_717_171_710)

      expect do
        perform_call_event(id: call_id, from: remote_jid, status: 'terminated', durationSeconds: 20, timestamp: 1_717_171_730)
        perform_call_event(id: call_id, from: remote_jid, status: 'hangup', durationSeconds: 35, timestamp: 1_717_171_745)
      end.not_to(change { conversation.reload.messages.voice_calls.count })

      data = sole_voice_call_data(conversation)
      meta = data['meta']
      expect(data).to include(expected_inbound_call_payload(call_id, remote_jid))
      expect(meta).to include(
        'created_at' => 1_717_171_700,
        'ringing_at' => 1_717_171_700,
        'started_at' => 1_717_171_710,
        'ended_at' => 1_717_171_730,
        'duration' => 20
      )
      expect_ordered_timestamps(meta, 'created_at', 'ringing_at', 'started_at', 'ended_at')
      expect(conversation.reload.additional_attributes).to include(
        'call_status' => 'completed',
        'call_direction' => 'inbound',
        'call_provider' => 'whatsapp_web',
        'call_source_id' => call_id,
        'call_started_at' => 1_717_171_710,
        'call_ended_at' => 1_717_171_730,
        'call_duration' => 20
      )
    end

    it 'records one unanswered inbound caller-hangup terminal event without inventing an answer timestamp' do
      call_id = 'call-unanswered-drop'
      remote_jid = '15550002222@s.whatsapp.net'
      perform_call_event(id: call_id, from: remote_jid, status: 'offer', isVideo: false, timestamp: 1_717_171_800)
      conversation = channel.inbox.conversations.last

      expect do
        perform_call_event(id: call_id, from: remote_jid, status: 'terminate', durationSeconds: 0, timestamp: 1_717_171_812)
        perform_call_event(id: call_id, from: remote_jid, status: 'terminated', durationSeconds: 4, timestamp: 1_717_171_820)
      end.not_to(change { conversation.reload.messages.voice_calls.count })

      data = sole_voice_call_data(conversation)
      meta = data['meta']
      expect(data).to include(expected_inbound_call_payload(call_id, remote_jid))
      expect(meta).to include(
        'created_at' => 1_717_171_800,
        'ringing_at' => 1_717_171_800,
        'ended_at' => 1_717_171_812,
        'duration' => 0
      )
      expect(meta).not_to have_key('started_at')
      expect_ordered_timestamps(meta, 'created_at', 'ringing_at', 'ended_at')
      expect(conversation.reload.additional_attributes).to include(
        'call_status' => 'completed',
        'call_direction' => 'inbound',
        'call_provider' => 'whatsapp_web',
        'call_source_id' => call_id,
        'call_ended_at' => 1_717_171_812,
        'call_duration' => 0
      )
      expect(conversation.additional_attributes).not_to have_key('call_started_at')
    end

    it 'does not trust outbound call display names for contact naming' do
      conversation = described_class.new(
        channel: channel,
        payload: {
          id: 'call-out-1',
          from: '15557654321@s.whatsapp.net',
          status: 'offer',
          fromMe: true,
          name: 'Akhan',
          timestamp: 1_717_171_717
        }
      ).perform

      expect(conversation).to be_present
      expect(conversation.contact.reload.name).to eq('+15557654321')
      expect(conversation.contact.additional_attributes['last_provider_display_name']).to be_nil
      expect(conversation.messages.voice_calls.last.message_type).to eq('outgoing')
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
      end.not_to(change { channel.inbox.messages.count })
    end
  end
end
