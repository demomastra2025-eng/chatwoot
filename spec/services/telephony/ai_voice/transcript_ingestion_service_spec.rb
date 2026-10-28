require 'rails_helper'

RSpec.describe Telephony::AiVoice::TranscriptIngestionService do
  let(:account) { create(:account) }
  let(:conversation) { create(:conversation, account: account) }
  let(:call_session) do
    create(:telephony_call_session, account: account, conversation: conversation, inbox: conversation.inbox,
                                    external_call_ref: 'test-ai-transcript-1', status: 'in_progress')
  end
  let(:voice_message) do
    create(:message, account: account, conversation: conversation, inbox: conversation.inbox,
                     content_type: :voice_call, source_id: call_session.voice_call_source_id,
                     content_attributes: { 'data' => {} })
  end

  before do
    voice_message
    timeline = instance_double(Telephony::AiVoice::ConversationTimelineService, sync_transcript_turns!: true)
    allow(Telephony::AiVoice::ConversationTimelineService).to receive(:new).and_return(timeline)
  end

  it 'merges successive transcript events into the session and voice message' do
    %w[Hello Goodbye].each do |word|
      described_class.new(payload: { account_id: account.id, call_ref: call_session.external_call_ref, final: true,
                                     items: [{ speaker: 'caller', text: word, at: Time.current.iso8601 }] }).perform
    end

    expect(call_session.reload.metadata.dig('ai_voice', 'transcript', 'final_items').pluck('text')).to eq(%w[Hello Goodbye])
    expect(voice_message.reload.content_attributes.dig('data', 'transcript')).to include('Hello Goodbye')
  end
end
