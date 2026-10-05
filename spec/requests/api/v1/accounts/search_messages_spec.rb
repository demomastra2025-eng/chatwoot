require 'rails_helper'

# The messages tab of the global search: literal text, who may find what, and what the answer says when the search was cut
# short by its time limit.
RSpec.describe 'Message text search API', type: :request do
  let(:account) { create(:account) }
  let(:agent) { create(:user, account: account, role: :agent) }
  # A new token ends the session of the previous one, so the token is created once per example.
  let(:headers) { agent.create_new_auth_token }
  let(:inbox) { create(:inbox, account: account, enable_auto_assignment: false) }
  let(:url) { "/api/v1/accounts/#{account.id}/search/messages" }
  let!(:conversation) { create(:conversation, account: account, inbox: inbox, assignee: agent) }

  before do
    create(:inbox_member, user: agent, inbox: inbox)
    create(:message, account: account, inbox: inbox, conversation: conversation, content: 'Хотите записаться на приём?')
    create(:message, account: account, inbox: inbox, conversation: conversation, content: 'Мы записали вас на среду')
  end

  def search(params)
    get url, headers: headers, params: params, as: :json
    expect(response).to have_http_status(:success), response.body
    response.parsed_body.deep_symbolize_keys
  end

  it 'finds the typed text exactly as typed: "записаться" does not find "записали"' do
    aggregate_failures do
      expect(search(q: 'записаться')[:payload][:messages].pluck(:content)).to eq(['Хотите записаться на приём?'])
      expect(search(q: 'записали')[:payload][:messages].pluck(:content)).to eq(['Мы записали вас на среду'])
      expect(search(q: 'на прием')[:payload][:messages].pluck(:content)).to eq(['Хотите записаться на приём?'])
    end
  end

  it 'says that nothing was cut short' do
    expect(search(q: 'записали')[:meta]).to eq(messages_partial: false)
  end

  it 'says so, and still answers, when the search of the text ran out of time' do
    allow_any_instance_of(Search::MessageQuery).to receive(:newest).and_return(Search::MessageQuery::Result.new([], true)) # rubocop:disable RSpec/AnyInstance

    body = search(q: 'записали')

    expect(body[:meta]).to eq(messages_partial: true)
    expect(body[:payload][:messages]).to eq([])
  end

  it 'answers a NUL byte, exotic spaces and operator characters with a normal answer, not a server error' do
    aggregate_failures do
      ["записали\u0000", "вас\u00A0на\u2009среду", 'a & b | (c', "50% _x_ \\", '!!!'].each do |text|
        get url, headers: headers, params: { q: text }, as: :json
        expect(response).to have_http_status(:success), "expected #{text.inspect} to be answered"
      end
    end
  end

  it 'pages the results' do
    21.times { |index| create(:message, account: account, inbox: inbox, conversation: conversation, content: "Нужна справка №#{index}", created_at: index.minutes.ago) }

    first_page = search(q: 'справка')[:payload][:messages]
    second_page = search(q: 'справка', page: 2)[:payload][:messages]

    expect(first_page.size).to eq(15)
    expect(second_page.size).to eq(6)
    expect(first_page.pluck(:id) & second_page.pluck(:id)).to be_empty
  end

  it 'does not return the text of a conversation a custom role cannot open' do
    custom_role = create(:custom_role, account: account, permissions: ['conversation_participating_manage'])
    agent.account_users.find_by(account: account).update!(custom_role: custom_role)
    hidden = create(:conversation, account: account, inbox: inbox)
    create(:message, account: account, inbox: inbox, conversation: hidden, content: 'Секретная справка про диагноз')
    create(:message, account: account, inbox: inbox, conversation: conversation, content: 'Нужная справка для вас')

    contents = search(q: 'справка')[:payload][:messages].pluck(:content)

    expect(contents).to eq(['Нужная справка для вас'])
    expect(response.body).not_to include('Секретная')
  end
end
