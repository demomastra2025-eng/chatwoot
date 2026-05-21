# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Llm::Evals::AiVoiceTraceExporter do
  let(:account) { create(:account) }
  let(:inbox) { create(:inbox, account: account) }
  let(:conversation) { create(:conversation, account: account, inbox: inbox) }
  let(:call_session) { create(:telephony_call_session, account: account, inbox: inbox, conversation: conversation) }

  def create_event(event_type, payload, created_at: Time.current)
    Telephony::Event.create!(
      account: account,
      call_session: call_session,
      event_key: SecureRandom.uuid,
      event_type: event_type,
      payload: payload,
      status: 'processed',
      created_at: created_at,
      updated_at: created_at
    )
  end

  it 'exports a sanitized AI Voice trace case from a conversation display id' do
    create_event('tool_completed', {
                   'payload' => {
                     'action' => 'tool_completed',
                     'tool_name' => 'search_deals',
                     'result' => { 'ok' => true, 'content' => 'Сделка #481, цена 250000 KZT', 'api_key' => 'secret' }
                   }
                 }, created_at: 2.minutes.ago)
    create_event('ai_transcript_turn', {
                   'payload' => { 'action' => 'ai_transcript_turn', 'role' => 'ai', 'content' => 'Цена 250000 KZT.' }
                 }, created_at: 1.minute.ago)

    exported = described_class.new(account: account, inbox_id: inbox.id, display_id: conversation.display_id).call

    expect(exported[:case]).to include(
      id: "conversation_#{conversation.display_id}_ai_voice_trace",
      tags: include('ai_voice', 'imported_conversation')
    )
    expect(exported.dig(:case, :events)).to include(
      include(action: 'tool_completed', tool_name: 'search_deals'),
      include(action: 'ai_transcript_turn', content: 'Цена 250000 KZT.')
    )
    expect(exported.dig(:case, :expected)).to include(
      forbid_actions: ['pacer_drop'],
      forbid_failed_tools: ['search_deals']
    )
    expect(exported[:yaml]).to include("conversation_#{conversation.display_id}")
    expect(exported[:yaml]).not_to include('secret')
  end

  it 'raises a not found error for conversations outside the account and inbox scope' do
    other_inbox = create(:inbox, account: account)

    expect do
      described_class.new(account: account, inbox_id: other_inbox.id, display_id: conversation.display_id).call
    end.to raise_error(ActiveRecord::RecordNotFound)
  end
end
