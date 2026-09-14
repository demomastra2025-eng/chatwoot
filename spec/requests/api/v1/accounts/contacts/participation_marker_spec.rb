# frozen_string_literal: true

require 'rails_helper'

RSpec.describe 'Contact participation marker', type: :request do
  let(:account) { create(:account).tap { |record| record.enable_features!('communication_threads') } }
  let(:participant) { create(:user, account: account, role: :agent) }
  let(:contact) { create(:contact, account: account, contact_type: :customer) }
  let(:conversation) { create(:conversation, account: account, contact: contact) }

  it 'marks participant-visible contacts in the global list' do
    create(:communication_thread_participant, communication_thread: conversation.communication_thread,
                                              user: participant, account: account)

    get "/api/v1/accounts/#{account.id}/contacts", headers: participant.create_new_auth_token, as: :json

    expect(response).to have_http_status(:success)
    serialized_contact = response.parsed_body.fetch('payload').find { |item| item.fetch('id').to_i == contact.id }
    expect(serialized_contact).to include('current_user_participant' => true)
  end
end
