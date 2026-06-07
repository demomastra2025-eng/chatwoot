# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Voice::CallStatus::Manager do
  let(:account) { create(:account) }
  let(:inbox) { create(:inbox, account: account) }
  let(:conversation) { create(:conversation, account: account, inbox: inbox) }

  it 'updates only the voice call message matching the call sid' do
    stale_message = create(
      :message,
      account: account,
      inbox: inbox,
      conversation: conversation,
      content_type: 'voice_call',
      content_attributes: {
        data: {
          call_sid: 'old-call-ref',
          status: 'ringing'
        }
      }
    )
    current_message = create(
      :message,
      account: account,
      inbox: inbox,
      conversation: conversation,
      content_type: 'voice_call',
      source_id: 'voice_call:fresh-call-ref',
      content_attributes: {
        data: {
          call_sid: 'fresh-call-ref',
          status: 'ringing'
        }
      }
    )

    described_class.new(conversation: conversation, call_sid: 'fresh-call-ref').process_status_update('completed')

    expect(stale_message.reload.content_attributes.dig('data', 'status')).to eq('ringing')
    expect(current_message.reload.content_attributes.dig('data', 'status')).to eq('completed')
  end

  it 'refreshes terminal metadata even when the canonical status is unchanged' do
    conversation.update!(
      additional_attributes: {
        'call_status' => 'completed',
        'call_started_at' => 100,
        'call_ended_at' => 120,
        'call_duration' => 20
      }
    )
    message = create(
      :message,
      account: account,
      inbox: inbox,
      conversation: conversation,
      content_type: 'voice_call',
      source_id: 'voice_call:fresh-call-ref',
      content_attributes: {
        data: {
          call_sid: 'fresh-call-ref',
          status: 'completed'
        }
      }.to_json
    )

    described_class.new(conversation: conversation, call_sid: 'fresh-call-ref').process_status_update(
      'completed',
      duration: 0,
      timestamp: 180
    )

    attrs = conversation.reload.additional_attributes
    expect(attrs['call_ended_at']).to eq(180)
    expect(attrs['call_duration']).to eq(0)
    expect(message.reload.content_attributes).to be_a(Hash)
    expect(message.content_attributes.dig('data', 'status')).to eq('completed')
  end

  it 'clears stale terminal metadata when the call returns to ringing' do
    conversation.update!(
      additional_attributes: {
        'call_status' => 'completed',
        'call_started_at' => 100,
        'call_ended_at' => 120,
        'call_duration' => 20
      }
    )

    described_class.new(conversation: conversation, call_sid: 'fresh-call-ref').process_status_update('ringing')

    attrs = conversation.reload.additional_attributes
    aggregate_failures do
      expect(attrs['call_status']).to eq('ringing')
      expect(attrs).not_to have_key('call_started_at')
      expect(attrs).not_to have_key('call_ended_at')
      expect(attrs).not_to have_key('call_duration')
    end
  end

  it 'refreshes active start time and clears stale terminal metadata for in-progress calls' do
    conversation.update!(
      additional_attributes: {
        'call_status' => 'completed',
        'call_started_at' => 100,
        'call_ended_at' => 120,
        'call_duration' => 20
      }
    )

    described_class.new(conversation: conversation, call_sid: 'fresh-call-ref').process_status_update(
      'in_progress',
      timestamp: 180
    )

    attrs = conversation.reload.additional_attributes
    aggregate_failures do
      expect(attrs['call_status']).to eq('in_progress')
      expect(attrs['call_started_at']).to eq(180)
      expect(attrs).not_to have_key('call_ended_at')
      expect(attrs).not_to have_key('call_duration')
    end
  end

  it 'does not mutate the latest voice call message when no message matches the call sid' do
    stale_message = create(
      :message,
      account: account,
      inbox: inbox,
      conversation: conversation,
      content_type: 'voice_call',
      content_attributes: {
        data: {
          call_sid: 'old-call-ref',
          status: 'completed'
        }
      }
    )

    described_class.new(conversation: conversation, call_sid: 'missing-call-ref').process_status_update('ringing')

    expect(stale_message.reload.content_attributes.dig('data', 'status')).to eq('completed')
  end
end
