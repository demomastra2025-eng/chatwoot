require 'rails_helper'

RSpec.describe 'Conversation list search API', type: :request do
  let(:account) { create(:account) }
  let(:agent) { create(:user, account: account, role: :agent) }
  # A new token ends the session of the previous one, so the token is created once per example.
  let(:headers) { agent.create_new_auth_token }
  let(:colleague) { create(:user, account: account, role: :agent) }
  let(:inbox) { create(:inbox, account: account) }
  let(:contact) { create(:contact, account: account, name: 'Иван Иванов', phone_number: '+77072817060') }
  # Resolved and assigned to a colleague: hidden by the "Open / Mine" filters of the list.
  let!(:conversation) { create(:conversation, account: account, inbox: inbox, contact: contact, status: :resolved, assignee: colleague) }
  let(:url) { "/api/v1/accounts/#{account.id}/conversations/list_search" }

  before do
    create(:inbox_member, user: agent, inbox: inbox)
    create(:message, account: account, conversation: conversation, inbox: inbox, message_type: :incoming, content: 'Хочу записаться на приём')
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

  it 'returns the conversations in the list format, with the number of found conversations' do
    body = search(q: 'Иванов')

    expect(response).to have_http_status(:success)
    expect(body[:data][:meta]).to include(search: true, total_count: 1, capped: false, partial: false, current_page: 1)
    expect(body[:data][:payload].pluck(:id)).to eq([conversation.display_id])
    expect(body[:data][:payload].first).to include(:meta, :messages, :unread_count, :status)
    expect(body[:data][:payload].first[:meta][:sender][:name]).to eq('Иван Иванов')
  end

  it 'searches all statuses and assignees even when the list is filtered to Open and Mine' do
    body = search(q: 'Иванов', status: 'open', assignee_type: 'me', inbox_id: create(:inbox, account: account).id, labels: ['vip'])

    expect(body[:data][:payload].pluck(:id)).to eq([conversation.display_id])
  end

  it 'finds the conversation by a phone number in any format and by the text of a message' do
    aggregate_failures do
      ['87072817060', '+7 (707) 281-70-60', '7 707 281 70 60', 'записаться'].each do |query|
        expect(search(q: query)[:data][:payload].pluck(:id)).to eq([conversation.display_id]), "expected #{query.inspect} to find the conversation"
      end
    end
  end

  it 'does not return conversations of an inbox the agent has no access to' do
    inaccessible_inbox = create(:inbox, account: account)
    inaccessible_inbox.inbox_members.where(user: agent).destroy_all
    hidden = create(:conversation, account: account, inbox: inaccessible_inbox, contact: contact)

    expect(search(q: 'Иванов')[:data][:payload].pluck(:id)).to eq([conversation.display_id])
    expect(search(q: 'Иванов')[:data][:payload].pluck(:id)).not_to include(hidden.display_id)
  end

  it 'returns an empty list for a query that is too short' do
    body = search(q: 'Ив')

    expect(response).to have_http_status(:success)
    expect(body[:data][:payload]).to eq([])
    expect(body[:data][:meta][:total_count]).to eq(0)
  end
  # The browser matches the channel profile (user name, display name, e-mail, phone) of the loaded items itself
  # (conversationSearch.js); its specs build their fixtures from this shape.
  def channel_profile_of(conversation)
    profile = conversation.contact_inbox.channel_profile || create(:contact_channel_profile, contact_inbox: conversation.contact_inbox)
    profile.update!(username: 'ada_channel_login', display_name: 'Ада в мессенджере', phone_number: '+77075550101', email: 'ada@channel.example')
  end

  it 'sends the channel profile in meta.contact_inbox and not on the sender' do
    channel_profile_of(conversation)

    item = search(q: 'Иванов')[:data][:payload].first

    expect(item[:meta][:contact_inbox][:channel_profile]).to include(
      username: 'ada_channel_login', display_name: 'Ада в мессенджере', phone_number: '+77075550101', email: 'ada@channel.example'
    )
    expect(item[:meta][:sender]).not_to include(:channel_profiles)
  end
end
