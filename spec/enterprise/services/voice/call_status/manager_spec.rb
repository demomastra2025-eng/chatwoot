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
