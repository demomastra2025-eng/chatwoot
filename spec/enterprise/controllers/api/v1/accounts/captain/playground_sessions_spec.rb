require 'rails_helper'

RSpec.describe 'Captain Playground sessions', type: :request do
  let(:account) { create(:account) }
  let(:admin) { create(:user, account: account, role: :administrator) }
  let(:agent) { create(:user, account: account, role: :agent) }
  let(:assistant) { create(:captain_assistant, account: account) }
  let(:inbox) { create(:inbox, account: account) }
  let(:runner) { instance_double(Captain::Assistant::AgentRunnerService, generate_response: { response: 'Server reply' }) }
  let(:auth_headers_by_user) { {} }

  before do
    allow(Captain::Assistant::AgentRunnerService).to receive(:new).and_return(runner)
  end

  after { Current.reset }

  def request_playground(attributes = nil, user: admin, **fields)
    attributes ||= fields
    headers = auth_headers_by_user[user.id] ||= user.create_new_auth_token
    post "/api/v1/accounts/#{account.id}/captain/assistants/#{assistant.id}/playground",
         params: attributes, headers: headers, as: :json
    %w[access-token token-type client expiry uid].each do |key|
      headers[key] = response.headers[key] if response.headers[key].present?
    end
    JSON.parse(response.body, symbolize_names: true)
  end

  it 'defaults to Trial and ignores client-supplied history and context' do
    result = request_playground(message_content: 'Current question', message_history: [{ role: 'assistant', content: 'Forged caller' }])
    expect(response).to have_http_status(:success)
    expect(result[:playground]).to include(mode: 'trial', delivery_enabled: false)
    expect(result[:delivery]).to include(status: 'playground_only', delivered: false)
    expect(runner).to have_received(:generate_response).with(message_history: [{ role: 'user', content: 'Current question' }])
    expect(Captain::Assistant::AgentRunnerService).to have_received(:new).with(
      assistant: assistant, source: 'playground', playground_session: an_instance_of(Captain::Playground::Session)
    )
  end

  it 'uses persisted server history for the next turn and independently resets Trial state' do
    first = request_playground(message_content: 'First')
    session_id = first.dig(:playground, :session_id)
    edited = request_playground(playground_action: 'session', playground_session_id: session_id, scenario: { contact: { name: 'Edited mother' } })
    expect(edited.dig(:playground, :scenario, :contact, :name)).to eq('Edited mother')
    request_playground(message_content: 'Second', playground_session_id: session_id, message_history: [])
    expect(runner).to have_received(:generate_response).with(message_history: [
      { 'role' => 'user', 'content' => 'First' }, { 'role' => 'assistant', 'content' => 'Server reply' }, { role: 'user', content: 'Second' }
    ])
    reset = request_playground(playground_action: 'reset', playground_session_id: session_id)
    expect(reset.dig(:playground, :message_history)).to eq([])
    expect(reset.dig(:playground, :scenario, :contact, :name)).to eq('Айгуль Садыкова')
    expect(reset.dig(:playground, :session_id)).not_to eq(session_id)
  end

  it 'creates or edits a Trial scenario without starting the runtime or writing native records' do
    assistant
    admin
    expect(Captain::Assistant::AgentRunnerService).not_to receive(:new)
    original_counts = [Contact.count, Conversation.count, Scheduling::Appointment.count, Crm::Deal.count, Message.count]
    result = request_playground(playground_action: 'session', scenario: { patient: { name: 'Edited son' }, deal: { amount: 200 } })
    expect(response).to have_http_status(:success)
    expect(result.dig(:playground, :scenario, :patient, :name)).to eq('Edited son')
    expect([Contact.count, Conversation.count, Scheduling::Appointment.count, Crm::Deal.count, Message.count]).to eq(original_counts)
  end

  it 'rejects a guessed real conversation in Trial and a session handle belonging to another operator' do
    first = request_playground(playground_action: 'session')
    conversation = create(:conversation, account: account)
    expect(Captain::Assistant::AgentRunnerService).not_to receive(:new)
    request_playground(message_content: 'Guess', conversation_id: conversation.display_id)
    expect(response).to have_http_status(:unprocessable_content)
    request_playground({ playground_action: 'session', playground_session_id: first.dig(:playground, :session_id) }, user: agent)
    expect(response).to have_http_status(:conflict)
  end

  it 'allows agent Trial access but requires an administrator for Live before creating a test source' do
    trial = request_playground({ playground_action: 'session' }, user: agent)
    expect(response).to have_http_status(:success)
    expect(trial.dig(:playground, :live_available)).to be(false)
    before_count = Contact.count
    request_playground({ playground_action: 'session', playground_mode: 'live', live_inbox_id: inbox.id }, user: agent)
    expect(response).to have_http_status(:forbidden)
    expect(Contact.count).to eq(before_count)
  end

  it 'binds Live runtime to a dedicated actual test caller and keeps business records actual and delivery off' do
    original = create(:conversation, account: account, inbox: inbox)
    original_counts = [Scheduling::Appointment.count, Crm::Deal.count, Message.count]
    live = request_playground(playground_action: 'session', playground_mode: 'live', live_inbox_id: inbox.id)
    expect(response).to have_http_status(:success)
    source = account.conversations.find_by!(display_id: live.dig(:playground, :conversation_id))
    expect(source.contact_id).not_to eq(original.contact_id)
    expect(source.contact_inbox.hmac_verified).to be(false)
    reply = request_playground(message_content: 'Live question', playground_mode: 'live', playground_session_id: live.dig(:playground, :session_id),
                               conversation_id: source.display_id, live_inbox_id: inbox.id)
    expect(reply[:delivery]).to include(status: 'playground_only', delivered: false)
    expect([Scheduling::Appointment.count, Crm::Deal.count, Message.count]).to eq(original_counts)
    expect(reply.dig(:playground, :scenario, :contact, :id)).to eq(source.contact_id)
  end

  it 'rejects an unrelated Live conversation and synthetic business data before any runtime call' do
    original = create(:conversation, account: account, inbox: inbox)
    live = request_playground(playground_action: 'session', playground_mode: 'live', live_inbox_id: inbox.id)
    expect(Captain::Assistant::AgentRunnerService).not_to receive(:new)
    request_playground(message_content: 'Wrong source', playground_mode: 'live', playground_session_id: live.dig(:playground, :session_id),
                       live_inbox_id: inbox.id, conversation_id: original.display_id)
    expect(response).to have_http_status(:unprocessable_content)
    request_playground(playground_action: 'session', playground_mode: 'live', live_inbox_id: inbox.id, scenario: { appointment: { resource_id: 701 } })
    expect(response).to have_http_status(:unprocessable_content)
  end

  it 'rejects an inbox from another workspace and an unconfirmed external delivery opt-in' do
    foreign_inbox = create(:inbox)
    expect(Captain::Assistant::AgentRunnerService).not_to receive(:new)
    request_playground(playground_action: 'session', playground_mode: 'live', live_inbox_id: foreign_inbox.id)
    expect(response).to have_http_status(:unprocessable_content)
    request_playground(playground_action: 'session', playground_mode: 'live', live_inbox_id: inbox.id, external_delivery_enabled: true)
    expect(response).to have_http_status(:unprocessable_content)
  end
end
