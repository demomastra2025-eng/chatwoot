# frozen_string_literal: true

require 'rails_helper'

RSpec.describe 'Communication thread participants API', type: :request do
  let(:account) { create(:account) }
  let(:owner) { create(:user, account: account) }
  let(:participant) { create(:user, account: account) }
  let(:other_agent) { create(:user, account: account) }
  let(:conversation) { create(:conversation, account: account, assignee: owner) }
  let(:communication_thread) { conversation.reload.communication_thread || conversation.refresh_communication_thread! }
  let(:base_path) do
    "/api/v1/accounts/#{account.id}/communication_threads/#{communication_thread.display_id}/participants"
  end

  before do
    account.enable_features!('communication_threads')
    communication_thread.update!(assignee: owner)
  end

  it 'allows the owner to add an individual workspace participant' do
    post base_path, params: { user_id: participant.id }, headers: owner.create_new_auth_token, as: :json

    expect(response).to have_http_status(:success)
    expect(response.parsed_body.pluck('id')).to contain_exactly(participant.id)
    expect(communication_thread.communication_thread_participants.exists?(user: participant)).to be(true)
  end

  it 'rejects participant management by an unrelated agent' do
    post base_path, params: { user_id: participant.id }, headers: other_agent.create_new_auth_token, as: :json

    expect(response).to have_http_status(:unauthorized)
  end

  it 'allows a participant to leave without allowing removal of another participant' do
    second_participant = create(:user, account: account)
    create(:communication_thread_participant, communication_thread: communication_thread, user: participant, account: account)
    create(:communication_thread_participant, communication_thread: communication_thread, user: second_participant, account: account)
    participant_headers = participant.create_new_auth_token

    delete base_path, params: { user_id: second_participant.id }, headers: participant_headers, as: :json
    expect(response).to have_http_status(:unauthorized)

    delete base_path, params: { user_id: participant.id }, headers: participant_headers, as: :json
    expect(response).to have_http_status(:success)
    expect(communication_thread.communication_thread_participants.exists?(user: participant)).to be(false)
  end

  it 'rejects users outside the account' do
    outsider = create(:user, account: create(:account))

    post base_path, params: { user_id: outsider.id }, headers: owner.create_new_auth_token, as: :json

    expect(response).to have_http_status(:not_found)
  end
end
