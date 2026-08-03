# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Captain::Tools::GetConfirmationRequestTool do
  let(:account) { create(:account) }
  let(:assistant) { create(:captain_assistant, account: account) }
  let(:conversation) { create(:conversation, account: account) }
  let(:tool_context) { Struct.new(:state).new({ conversation: { id: conversation.id } }) }
  let(:tool) { described_class.new(assistant) }

  it 'returns the latest request from the current conversation without its callback token' do
    older = create(:confirmation_request, account: account, conversation: conversation, created_at: 2.minutes.ago)
    latest = create(:confirmation_request, account: account, conversation: conversation, created_at: 1.minute.ago)

    payload = JSON.parse(tool.perform(tool_context))

    expect(payload['action']).to eq('get_confirmation_request')
    expect(payload.dig('confirmation_request', 'id')).to eq(latest.id)
    expect(payload['confirmation_request']).not_to have_key('token')
    expect(payload.dig('confirmation_request', 'id')).not_to eq(older.id)
  end

  it 'fails closed for a request outside the current account and conversation' do
    other_request = create(:confirmation_request)

    result = tool.perform(tool_context, confirmation_request_id: other_request.id)

    expect(result).to start_with('ERROR: ActiveRecord::RecordNotFound')
  end
end
