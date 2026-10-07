require 'rails_helper'

RSpec.describe 'Global search conversation navigation', type: :request do
  let(:account) { create(:account) }
  let(:agent) { create(:user, account: account, role: :agent) }
  let(:headers) { agent.create_new_auth_token }
  let(:inbox) { create(:inbox, account: account, enable_auto_assignment: false) }
  let(:contact) { create(:contact, account: account, name: 'Иван Иванов', email: 'ivan.ivanov@example.com') }
  let!(:first_conversation) { create(:conversation, account: account, inbox: inbox, contact: contact, assignee: agent, status: :resolved) }
  let!(:latest_conversation) { create(:conversation, account: account, inbox: inbox, contact: contact, assignee: agent) }
  let!(:message) { create(:message, account: account, inbox: inbox, conversation: first_conversation, content: 'Нужна справка') }

  before do
    account.enable_features!('communication_threads')
    create(:inbox_member, user: agent, inbox: inbox)
    # The conversations were built before the feature was switched on: reload them so they see the account flag.
    first_conversation.reload.refresh_communication_thread!
    latest_conversation.reload.refresh_communication_thread!
    latest_conversation.update!(last_activity_at: 1.minute.from_now)
  end

  def search(type, query)
    get "/api/v1/accounts/#{account.id}/search/#{type}", headers: headers, params: { q: query }, as: :json
    expect(response).to have_http_status(:success), response.body
    response.parsed_body.fetch('payload').fetch(type)
  end

  it 'returns the thread display id for both conversations and the message anchor' do
    thread_id = first_conversation.reload.communication_thread.display_id

    conversations = search('conversations', 'Иванов')
    message_result = search('messages', 'Нужна справка').find { |item| item.fetch('id') == message.id }

    expect(conversations.pluck('communication_thread_id')).to eq([thread_id, thread_id])
    expect(message_result).to include('conversation_id' => first_conversation.display_id, 'communication_thread_id' => thread_id)
  end

  it 'points the contact hit at the latest accessible conversation and its thread' do
    result = search('contacts', 'Иванов').find { |item| item.fetch('id') == contact.id }

    expect(result.fetch('latest_conversation')).to include(
      'id' => latest_conversation.display_id,
      'inbox_id' => inbox.id,
      'communication_thread_id' => latest_conversation.reload.communication_thread.display_id
    )
  end

  it 'keeps conversation targets when the account does not use thread mode' do
    account.disable_features!('communication_threads')

    expect(search('conversations', 'Иванов').first).not_to have_key('communication_thread_id')
    contact_result = search('contacts', 'Иванов').find { |item| item.fetch('id') == contact.id }
    expect(contact_result.fetch('latest_conversation')).not_to have_key('communication_thread_id')
  end

  it 'does not expose a hidden conversation or use it as the contact target' do
    custom_role = create(:custom_role, account: account, permissions: %w[conversation_participating_manage contact_manage])
    agent.account_users.find_by(account: account).update!(custom_role: custom_role)
    colleague = create(:user, account: account, role: :agent)
    hidden = create(:conversation, account: account, inbox: inbox, contact: contact, assignee: colleague)
    hidden.reload.refresh_communication_thread!
    create(:message, account: account, inbox: inbox, conversation: hidden, content: 'Секретная справка')

    conversations = search('conversations', 'Иванов')
    contact_result = search('contacts', 'Иванов').find { |item| item.fetch('id') == contact.id }

    expect(conversations.pluck('id')).not_to include(hidden.display_id)
    expect(contact_result.fetch('latest_conversation').fetch('id')).to eq(latest_conversation.display_id)
    expect(search('messages', 'Секретная справка')).to be_empty
    expect(response.body).not_to include('Секретная')
  end

  it 'does not return an inaccessible thread identifier' do
    custom_role = create(:custom_role, account: account, permissions: %w[conversation_participating_manage contact_manage])
    agent.account_users.find_by(account: account).update!(custom_role: custom_role)
    hidden_contact = create(:contact, account: account, name: 'Скрытый Петров', email: 'hidden.petrov@example.com')
    hidden = create(:conversation, account: account, inbox: inbox, contact: hidden_contact)
    hidden.reload.refresh_communication_thread!

    expect(search('conversations', 'Скрытый Петров')).to be_empty
    contact_result = search('contacts', 'Скрытый Петров').find { |item| item.fetch('id') == hidden_contact.id }
    expect(contact_result).not_to have_key('latest_conversation')
  end
end
