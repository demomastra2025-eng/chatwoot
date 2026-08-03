# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Captain::Tools::Copilot::GetConfirmationRequestService do
  let(:account) { create(:account) }
  let(:user) { create(:user, account: account, role: :administrator) }
  let(:assistant) { create(:captain_assistant, account: account) }
  let(:conversation) { create(:conversation, account: account) }
  let(:service) { described_class.new(assistant, user: user, conversation: conversation) }

  it 'returns the latest permissible request without exposing its callback token' do
    create(:confirmation_request, account: account, conversation: conversation, created_at: 2.minutes.ago)
    latest = create(:confirmation_request, account: account, conversation: conversation, created_at: 1.minute.ago)

    payload = JSON.parse(service.execute)

    expect(payload.dig('confirmation_request', 'id')).to eq(latest.id)
    expect(payload['confirmation_request']).not_to have_key('token')
  end

  it 'does not expose requests outside the operator account' do
    other_request = create(:confirmation_request)

    expect(service.execute(confirmation_request_id: other_request.id)).to eq('ERROR: Confirmation request not found')
  end
end
