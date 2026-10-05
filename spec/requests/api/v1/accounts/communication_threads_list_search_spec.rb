require 'rails_helper'

RSpec.describe 'Communication thread list search API', type: :request do
  let(:account) { create(:account) }
  let(:agent) { create(:user, account: account, role: :agent) }
  # A new token ends the session of the previous one, so the token is created once per example.
  let(:headers) { agent.create_new_auth_token }
  let(:colleague) { create(:user, account: account, role: :agent) }
  let(:inbox) { create(:inbox, account: account) }
  let(:contact) { create(:contact, account: account, name: 'Иван Иванов', phone_number: '+77072817060') }
  let(:url) { "/api/v1/accounts/#{account.id}/communication_threads/list_search" }
  let(:conversation) do
    create(:conversation, account: account, inbox: inbox, contact: contact, status: :resolved, assignee: colleague)
  end
  let(:thread) do
    conversation.reload.refresh_communication_thread!
    conversation.reload.communication_thread
  end

  before do
    account.enable_features!('communication_threads')
    create(:inbox_member, user: agent, inbox: inbox)
    create(:message, account: account, conversation: conversation, inbox: inbox, message_type: :incoming, content: 'Хочу записаться на приём')
    thread
  end

  def search(search_params)
    get url, headers: headers, params: search_params, as: :json
    expect(response).to have_http_status(:success), response.body
    response.parsed_body.deep_symbolize_keys
  end

  it 'returns unauthorized without a user' do
    get url, params: { q: 'Иванов' }

    expect(response).to have_http_status(:unauthorized)
  end

  it 'returns forbidden when the communication threads feature is disabled' do
    account.disable_features!('communication_threads')

    get url, headers: headers, params: { q: 'Иванов' }, as: :json

    expect(response).to have_http_status(:forbidden)
  end

  it 'returns the threads in the list format, with the number of found threads' do
    body = search(q: 'Иванов')

    expect(response).to have_http_status(:success)
    expect(body[:data][:meta]).to include(search: true, total_count: 1, capped: false, partial: false, current_page: 1)
    expect(body[:data][:payload].pluck(:id)).to eq([thread.display_id])
  end

  it 'searches all statuses and assignees even when the list is filtered to Open and Mine' do
    body = search(q: 'Иванов', status: 'open', assignee_type: 'me', inbox_id: create(:inbox, account: account).id, labels: ['vip'])

    expect(body[:data][:payload].pluck(:id)).to eq([thread.display_id])
  end

  it 'finds the thread by a phone number in any format and by the text of a message' do
    aggregate_failures do
      ['87072817060', '+7 (707) 281-70-60', '7 707 281 70 60', 'записаться'].each do |query|
        expect(search(q: query)[:data][:payload].pluck(:id)).to eq([thread.display_id]), "expected #{query.inspect} to find the thread"
      end
    end
  end

  it 'does not return the contact of a conversation a custom role cannot open, found through its message text' do
    custom_role = create(:custom_role, account: account, permissions: ['conversation_participating_manage'])
    agent.account_users.find_by(account: account).update!(custom_role: custom_role)
    hidden_contact = create(:contact, account: account, name: 'Скрытый Петров', phone_number: '+77015550000')
    hidden = create(:conversation, account: account, inbox: inbox, contact: hidden_contact)
    hidden.reload.refresh_communication_thread!
    create(:message, account: account, conversation: hidden, inbox: inbox, message_type: :incoming, content: 'Секретная справка про диагноз')

    body = search(q: 'секретная справка')

    expect(body[:data][:payload]).to be_empty
    expect(response.body).not_to include('Скрытый')
  end

  it 'does not return a thread of conversations in inboxes the agent has no access to' do
    other_contact = create(:contact, account: account, name: 'Скрытый Иванов')
    hidden = create(:conversation, account: account, inbox: create(:inbox, account: account), contact: other_contact)
    hidden.reload.refresh_communication_thread!

    expect(search(q: 'Иванов')[:data][:payload].pluck(:id)).to eq([thread.display_id])
  end
end
