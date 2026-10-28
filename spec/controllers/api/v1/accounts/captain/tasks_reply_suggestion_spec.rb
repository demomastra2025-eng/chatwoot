# frozen_string_literal: true

require 'rails_helper'

RSpec.describe 'Api::V1::Accounts::Captain::Tasks reply suggestion', type: :request do
  let(:account) { create(:account) }
  let(:agent) { create(:user, account: account, role: :agent) }
  let(:admin) { create(:user, account: account, role: :administrator) }
  let(:inbox) { create(:inbox, account: account) }
  let(:conversation) { create(:conversation, account: account, inbox: inbox) }
  let(:tasks_path) { "/api/v1/accounts/#{account.id}/captain/tasks" }
  let(:store) { Captain::ReplySuggestion::RequestStore }
  let(:headers) { agent.create_new_auth_token }
  # A new user joins every inbox of the account, and a new inbox takes every user: an outsider is one that was taken out of the inbox.
  let(:outsider) do
    conversation
    create(:user, account: account, role: :agent).tap { |user| InboxMember.where(user_id: user.id).delete_all }
  end

  def json_response
    JSON.parse(response.body, symbolize_names: true)
  end

  include_context 'with a configured reply suggestion model'

  before do
    Llm::EventSubscriber.install!
    account.enable_features!('captain_integration', 'captain_tasks')
  end

  def start(user_headers = headers, display_id: conversation.display_id)
    post "#{tasks_path}/reply_suggestion", params: { conversation_display_id: display_id }, headers: user_headers, as: :json
  end

  def state_for(user, status: 'queued', result: nil, **attributes)
    record = store.create!(
      'account_id' => account.id, 'user_id' => user.id, 'conversation_id' => conversation.id, 'conversation_display_id' => conversation.display_id,
      'engine' => 'agent', 'assistant_id' => 1, 'based_on_message_id' => nil, **attributes.stringify_keys
    )
    status == 'queued' ? record : store.finish!(record, status: status, result: result)
  end

  describe 'POST /reply_suggestion' do
    it 'answers 202 at once with the state of the request, and queues the job' do
      expect { start }.to have_enqueued_job(Captain::ReplySuggestion::GenerateJob).on_queue('captain_suggestions')

      expect(response).to have_http_status(:accepted)
      expect(json_response.keys).to match_array(
        %i[suggestion_request_id status reused engine conversation_id conversation_record_id created_at started_at finished_at deadline_at
           budget_seconds duration_ms stale progress result]
      )
      expect(json_response).to include(
        status: 'queued', reused: false, engine: 'legacy_prompt', conversation_id: conversation.display_id, conversation_record_id: conversation.id,
        started_at: nil, finished_at: nil, deadline_at: nil, budget_seconds: 60, duration_ms: nil, stale: false, progress: nil, result: nil
      )
    end

    it 'gives the state that is already running to a second click, and runs no second job' do
      start
      first = json_response

      expect { start }.not_to have_enqueued_job(Captain::ReplySuggestion::GenerateJob)

      expect(response).to have_http_status(:accepted)
      expect(json_response).to include(suggestion_request_id: first[:suggestion_request_id], reused: true)
    end

    it 'lets an administrator ask for a conversation of any inbox' do
      start(admin.create_new_auth_token)

      expect(response).to have_http_status(:accepted)
    end

    it 'answers 404 conversation_not_found for an id that does not resolve' do
      start(headers, display_id: 987_654)

      expect(response).to have_http_status(:not_found)
      expect(json_response).to eq(
        error: I18n.t('captain.reply_suggestion.errors.conversation_not_found', locale: account.locale), error_code: 'conversation_not_found'
      )
    end

    it 'answers 403 for a manager who cannot see the conversation, and starts nothing' do
      expect { start(outsider.create_new_auth_token) }.not_to have_enqueued_job(Captain::ReplySuggestion::GenerateJob)

      expect(response).to have_http_status(:forbidden)
      expect(json_response[:error_code]).to eq('forbidden')
    end

    it 'answers 403 text_improvement_disabled when an admin switched text improvement off, with an unavailable event' do
      account.update!(captain_features: { 'text_improvement' => false })

      expect { start }.not_to have_enqueued_job(Captain::ReplySuggestion::GenerateJob)

      expect(response).to have_http_status(:forbidden)
      expect(json_response).to eq(error: I18n.t('captain.text_improvement_disabled', locale: account.locale), error_code: 'text_improvement_disabled')
      unavailable = LlmEvent.where(event_name: 'captain.reply_suggestion.complete', status: 'unavailable')
      expect(unavailable.pluck(:reason)).to eq(['text_improvement_disabled'])
    end

    it 'answers 403 disabled when captain tasks are off' do
      account.disable_features!('captain_tasks')

      start

      expect(response).to have_http_status(:forbidden)
      expect(json_response[:error_code]).to eq('disabled')
    end

    it 'answers 422 api_key_missing' do
      allow(Llm::Config).to receive(:api_key).and_return(nil)

      start

      expect(response).to have_http_status(:unprocessable_content)
      expect(json_response[:error_code]).to eq('api_key_missing')
    end

    it 'answers 422 voice_channel_unsupported for a voice conversation' do
      voice_conversation = create(:conversation, account: account, inbox: create(:channel_voice, :sipuni, account: account).inbox)

      expect { start(display_id: voice_conversation.display_id) }.not_to have_enqueued_job(Captain::ReplySuggestion::GenerateJob)

      expect(response).to have_http_status(:unprocessable_content)
      expect(json_response[:error_code]).to eq('voice_channel_unsupported')
    end

    it 'answers 429 busy when the account already has the most runs it may have' do
      allow(Captain::ReplySuggestion).to receive(:max_active_per_account).and_return(1)
      Redis::Alfred.zadd(Captain::ReplySuggestion::RequestLocks.account_active_key(account.id), Time.current.to_i + 100, 'another')

      start

      expect(response).to have_http_status(:too_many_requests)
      expect(json_response[:error_code]).to eq('busy')
    end

    it 'still requires authentication' do
      post "#{tasks_path}/reply_suggestion", params: { conversation_display_id: conversation.display_id }, as: :json

      expect(response).to have_http_status(:unauthorized)
    end
  end

  # One person, two channels: the open WhatsApp dialog and a newer Telegram conversation that was resolved.
  describe 'a person with a communication thread' do
    let(:newer_resolved) do
      create(:conversation, account: account, contact: conversation.contact, inbox: create(:inbox, account: account), status: :resolved)
    end
    let(:thread) { create(:communication_thread, account: account, contact: conversation.contact, display_id: 7001) }

    before do
      [conversation, newer_resolved].each do |linked|
        create(:communication_thread_conversation, communication_thread: thread, conversation: linked)
      end
    end

    it 'takes a display id of the thread for the conversation in front of it, the open one, not the newest one' do
      expect(newer_resolved.id).to be > conversation.id

      start(headers, display_id: thread.display_id)

      expect(response).to have_http_status(:accepted)
      expect(json_response).to include(conversation_id: 7001, conversation_record_id: conversation.id)
      get "#{tasks_path}/reply_suggestion_status", params: { conversation_display_id: thread.display_id }, headers: headers
      expect(json_response[:suggestion]).to include(conversation_record_id: conversation.id, status: 'queued')
    end

    it 'bases the suggestion on the latest customer message of the person and tells it is stale after one in another channel' do
      first = create(:message, conversation: newer_resolved, account: account, message_type: :incoming, content: 'Нужен ЛОР')
      start
      id = json_response[:suggestion_request_id]
      expect(store.fetch_raw(id)['based_on_message_id']).to eq(first.id)
      store.finish!(store.fetch_raw(id), status: 'draft', result: { 'message' => 'Здравствуйте' })

      get "#{tasks_path}/reply_suggestion_status", params: { conversation_display_id: conversation.display_id }, headers: headers
      expect(json_response[:suggestion]).to include(suggestion_request_id: id, stale: false)

      create(:message, conversation: newer_resolved, account: account, message_type: :incoming, content: 'А на завтра?')
      get "#{tasks_path}/reply_suggestion_status", params: { conversation_display_id: conversation.display_id }, headers: headers
      expect(json_response[:suggestion]).to include(suggestion_request_id: id, stale: true)
    end
  end

  describe 'GET /reply_suggestion_status' do
    def status(params = {}, user_headers = headers)
      get "#{tasks_path}/reply_suggestion_status", params: { conversation_display_id: conversation.display_id }.merge(params), headers: user_headers
    end

    it 'answers null when there is nothing' do
      status

      expect(response).to have_http_status(:ok)
      expect(json_response).to eq(suggestion: nil)
    end

    it 'gives the latest state of the manager in the conversation, with the lazy view of a queued request' do
      record = state_for(agent)

      status

      expect(json_response[:suggestion]).to include(suggestion_request_id: record['id'], status: 'queued', result: nil, engine: 'agent')
      expect(json_response[:suggestion]).not_to have_key(:reused)
    end

    it 'gives a finished draft with its result and the stale flag' do
      record = state_for(agent, status: 'draft', result: { 'message' => 'Здравствуйте!', 'agent' => nil, 'pending_actions' => [] })

      status

      expect(json_response[:suggestion]).to include(suggestion_request_id: record['id'], status: 'draft', stale: false)
      expect(json_response.dig(:suggestion, :result)).to include(message: 'Здравствуйте!', pending_actions: [])
    end

    it 'does not show the suggestion of another manager' do
      other = create(:user, account: account, role: :agent)
      state_for(other)

      status

      expect(json_response).to eq(suggestion: nil)
    end

    it 'does not show a suggestion the manager acted on, or cancelled' do
      acted = state_for(agent, status: 'draft', result: { 'message' => 'Привет' })
      store.consume!(acted['id'])
      status
      expect(json_response).to eq(suggestion: nil)

      cancelled = state_for(agent)
      store.request_cancel!(cancelled['id'])
      status
      expect(json_response).to eq(suggestion: nil)
    end

    it 'shows an old queued request as failed{queue_timeout} and a lost running one as failed{interrupted}' do
      queued = state_for(agent, created_at: (Time.current - 200).utc.iso8601(3))
      status
      expect(json_response[:suggestion]).to include(suggestion_request_id: queued['id'], status: 'failed', result: { reason_code: 'queue_timeout' })

      running = store.mark_running!(state_for(agent), started_at: Time.current - 300, deadline_at: Time.current - 240)
      status
      expect(json_response[:suggestion]).to include(suggestion_request_id: running['id'], status: 'failed', result: { reason_code: 'interrupted' })
    end

    it 'tells that new customer messages came after the suggestion was requested' do
      first = create(:message, conversation: conversation, account: account, message_type: :incoming, content: 'Нужен ЛОР')
      state_for(agent, status: 'draft', result: { 'message' => 'Привет' }, based_on_message_id: first.id)
      status
      expect(json_response.dig(:suggestion, :stale)).to be(false)

      create(:message, conversation: conversation, account: account, message_type: :incoming, content: 'А на завтра?')
      create(:message, conversation: conversation, account: account, message_type: :incoming, content: 'Заметка', private: true)
      status
      expect(json_response.dig(:suggestion, :stale)).to be(true)
    end

    it 'gives the progress snapshot of a running request' do
      running = store.mark_running!(state_for(agent), started_at: Time.current, deadline_at: Time.current + 60)
      store.write_progress(running['id'], { phase: 'tool_running', elapsed_ms: 4100 })

      status

      expect(json_response[:suggestion]).to include(status: 'running', progress: { phase: 'tool_running', elapsed_ms: 4100 })
    end

    describe 'by the id of the request' do
      it 'gives it even when it was acted on: the dashboard asks after a missed event' do
        record = state_for(agent, status: 'draft', result: { 'message' => 'Привет' })
        store.consume!(record['id'])

        status(suggestion_request_id: record['id'])

        expect(json_response[:suggestion]).to include(suggestion_request_id: record['id'], status: 'draft')
      end

      it 'answers 404 for a request of another manager or of another conversation, and for an unknown one' do
        other = create(:user, account: account, role: :agent)
        theirs = state_for(other)
        status(suggestion_request_id: theirs['id'])
        expect(response).to have_http_status(:not_found)
        expect(json_response[:error_code]).to eq('not_found')

        status(suggestion_request_id: SecureRandom.uuid)
        expect(response).to have_http_status(:not_found)

        elsewhere = create(:conversation, account: account, inbox: inbox)
        mine = state_for(agent)
        get "#{tasks_path}/reply_suggestion_status",
            params: { conversation_display_id: elsewhere.display_id, suggestion_request_id: mine['id'] }, headers: headers
        expect(response).to have_http_status(:not_found)
      end
    end

    it 'answers 403 for a manager who cannot see the conversation, and 404 for an unknown conversation' do
      status({}, outsider.create_new_auth_token)
      expect(response).to have_http_status(:forbidden)

      status(conversation_display_id: 987_654)
      expect(response).to have_http_status(:not_found)
      expect(json_response[:error_code]).to eq('conversation_not_found')
    end

    it 'stays readable after text improvement is switched off' do
      account.update!(captain_features: { 'text_improvement' => false })

      status

      expect(response).to have_http_status(:ok)
    end
  end

  describe 'POST /cancel_reply_suggestion' do
    def cancel(id, user_headers = headers)
      post "#{tasks_path}/cancel_reply_suggestion", params: { conversation_display_id: conversation.display_id, suggestion_request_id: id },
                                                    headers: user_headers, as: :json
    end

    it 'sets the cancel flag that stops the run on the server, and the suggestion never reappears' do
      record = state_for(agent)

      cancel(record['id'])

      expect(response).to have_http_status(:ok)
      expect(json_response).to eq(suggestion_request_id: record['id'], status: 'cancelling')
      expect(store.cancel_requested?(record['id'])).to be(true)
      expect(store.consumed?(record['id'])).to be(true)
      cancelled_event = LlmEvent.where(event_name: 'llm.copilot.feedback', request_id: record['id'], status: 'cancelled').sole
      expect(cancelled_event.payload).to include('suggestion_request_id' => record['id'], 'user_id' => agent.id)
      expect(Redis::Alfred.get("#{store::PREFIX}:dismissed:#{account.id}:#{agent.id}:#{conversation.id}")).to include(record['id'])
    end

    it 'says cancelling for a running request too' do
      running = store.mark_running!(state_for(agent), started_at: Time.current, deadline_at: Time.current + 60)

      cancel(running['id'])

      expect(json_response).to eq(suggestion_request_id: running['id'], status: 'cancelling')
    end

    it 'reports the final status of a request that has finished, and still makes it never reappear' do
      record = state_for(agent, status: 'draft', result: { 'message' => 'Привет' })

      cancel(record['id'])

      expect(json_response).to eq(suggestion_request_id: record['id'], status: 'draft')
      expect(store.consumed?(record['id'])).to be(true)
    end

    it 'is for the manager who asked only: another manager gets 404 and stops nothing' do
      other = create(:user, account: account, role: :agent)
      theirs = state_for(other)

      cancel(theirs['id'])

      expect(response).to have_http_status(:not_found)
      expect(store.cancel_requested?(theirs['id'])).to be(false)
    end

    it 'answers 404 for an unknown request and 403 for a conversation the manager cannot see' do
      cancel(SecureRandom.uuid)
      expect(response).to have_http_status(:not_found)

      cancel(state_for(agent)['id'], outsider.create_new_auth_token)
      expect(response).to have_http_status(:forbidden)
    end

    it 'works after text improvement is switched off' do
      account.update!(captain_features: { 'text_improvement' => false })

      cancel(state_for(agent)['id'])

      expect(response).to have_http_status(:ok)
    end
  end

  describe 'POST /feedback' do
    let(:draft) { state_for(agent, status: 'draft', result: { 'message' => 'Здравствуйте! Окно завтра в 10:00.' }) }

    def feedback(params, user_headers = headers)
      post "#{tasks_path}/feedback", headers: user_headers, as: :json,
                                     params: { conversation_display_id: conversation.display_id, copilot_action: 'reply_suggestion' }.merge(params)
    end

    def events(status)
      LlmEvent.where(event_name: 'llm.copilot.feedback', status: status).order(:id)
    end

    it 'accepts the outcome of a notice the manager closed, and records it on the request' do
      notice = state_for(agent, status: 'no_reply', result: { 'reason' => 'Только благодарность.' })

      feedback(outcome: 'notice_dismissed', suggestion_request_id: notice['id'])

      expect(response).to have_http_status(:ok)
      expect(json_response).to eq(ok: true, status: 'ok')
      expect(events('notice_dismissed').sole).to have_attributes(request_id: notice['id'], source: 'reply_suggestion')
      expect(events('notice_dismissed').sole.payload).to include('suggestion_request_id' => notice['id'], 'reason_preview' => 'Только благодарность.')
      expect(store.consumed?(notice['id'])).to be(true)
    end

    it 'records that the draft was inserted, and the suggestion never reappears' do
      feedback(outcome: 'applied', suggestion_request_id: draft['id'], generated_text: 'Здравствуйте! Окно завтра в 10:00.')

      expect(events('applied').sole).to have_attributes(request_id: draft['id'], account_id: account.id, conversation_id: conversation.id)
      expect(events('applied').sole.payload).to include('user_id' => agent.id, 'suggestion_outcome' => 'applied', 'engine' => 'agent')
      expect(store.consumed?(draft['id'])).to be(true)
      get "#{tasks_path}/reply_suggestion_status", params: { conversation_display_id: conversation.display_id }, headers: headers
      expect(json_response).to eq(suggestion: nil)
    end

    it 'records the sent text as the manager sent it, with the text of the suggestion, in full' do
      sent_text = 'Здравствуйте! Окно завтра в 10:30.'
      sent = create(:message, conversation: conversation, account: account, message_type: :outgoing, sender: agent, content: sent_text)

      feedback(outcome: 'sent', suggestion_request_id: draft['id'], message_id: sent.id, edited_before_send: true, follow_up_count: 1,
               generated_text: 'Здравствуйте! Окно завтра в 10:00.', final_text: 'клиентская копия')

      event = events('sent').sole
      expect(event.request_id).to eq(draft['id'])
      expect(event.payload).to include(
        'suggestion_text' => 'Здравствуйте! Окно завтра в 10:00.', 'final_text' => sent_text, 'message_id' => sent.id,
        'edited_before_send' => true, 'follow_up_count' => 1, 'user_id' => agent.id
      )
      expect(event.payload).not_to include('generated_reply_preview', 'final_reply_preview')
    end

    it 'does not take the text of a message that is not the manager\'s own from the database' do
      someone_else = create(:message, conversation: conversation, account: account, message_type: :outgoing, sender: create(:user, account: account),
                                      content: 'Чужое сообщение')

      feedback(outcome: 'sent', suggestion_request_id: draft['id'], message_id: someone_else.id, generated_text: 'A', final_text: 'Текст с клиента')

      expect(events('sent').sole.payload).to include('final_text' => 'Текст с клиента')
    end

    it 'records the dismissed draft with its text and waits for what the manager writes instead' do
      feedback(outcome: 'dismissed', suggestion_request_id: draft['id'])

      expect(events('dismissed').sole.payload)
        .to include('suggestion_text' => 'Здравствуйте! Окно завтра в 10:00.', 'suggestion_request_id' => draft['id'])
      expect(store.consumed?(draft['id'])).to be(true)
      expect(Redis::Alfred.get("#{store::PREFIX}:dismissed:#{account.id}:#{agent.id}:#{conversation.id}")).to be_present
    end

    it 'has no field for a correct answer and creates no FAQ candidate: it is ignored' do
      expect do
        feedback(outcome: 'dismissed', suggestion_request_id: draft['id'], correct_answer: 'Принимаем с года')
      end.not_to change(Captain::AssistantResponse, :count)

      expect(response).to have_http_status(:ok)
      expect(json_response).to eq(ok: true, status: 'ok')
      expect(events('dismissed').sole.payload.keys).not_to include('correct_answer_preview', 'faq_candidate_id', 'faq_candidate_status')
    end

    it 'answers 404 for a request that is not the manager\'s own, unknown, or in another conversation' do
      other = create(:user, account: account, role: :agent)
      feedback(outcome: 'applied', suggestion_request_id: state_for(other)['id'])
      expect(response).to have_http_status(:not_found)

      feedback(outcome: 'applied', suggestion_request_id: SecureRandom.uuid)
      expect(response).to have_http_status(:not_found)

      elsewhere = create(:conversation, account: account, inbox: inbox)
      post "#{tasks_path}/feedback", headers: headers, as: :json,
                                     params: { conversation_display_id: elsewhere.display_id, outcome: 'applied', suggestion_request_id: draft['id'] }
      expect(response).to have_http_status(:not_found)
      expect(events('applied')).to be_empty
    end

    it 'answers 403 for a manager who cannot see the conversation' do
      feedback({ outcome: 'applied', suggestion_request_id: draft['id'] }, outsider.create_new_auth_token)

      expect(response).to have_http_status(:forbidden)
      expect(events('applied')).to be_empty
    end

    it 'rejects an outcome it does not know' do
      feedback(outcome: 'liked', suggestion_request_id: draft['id'])

      expect(response).to have_http_status(:unprocessable_content)
    end

    it 'works after text improvement is switched off' do
      account.update!(captain_features: { 'text_improvement' => false })

      feedback(outcome: 'applied', suggestion_request_id: draft['id'])

      expect(response).to have_http_status(:ok)
    end
  end
end
