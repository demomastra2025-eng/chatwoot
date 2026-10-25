require 'rails_helper'

RSpec.describe Captain::ReplySuggestion::StartService do
  subject(:service) do
    described_class.new(account: account, user: agent, conversation: conversation, conversation_display_id: conversation.display_id)
  end

  let(:account) { create(:account) }
  let(:agent) { create(:user, account: account, role: :agent) }
  let(:inbox) { create(:inbox, account: account) }
  let(:conversation) { create(:conversation, account: account, inbox: inbox) }

  include_context 'with a configured reply suggestion model'

  before do
    Llm::EventSubscriber.install!
    account.enable_features!('captain_integration', 'captain_tasks')
  end

  def unavailable_events
    LlmEvent.where(event_name: 'captain.reply_suggestion.complete', status: 'unavailable')
  end

  describe 'a request that can start' do
    let!(:incoming) { create(:message, conversation: conversation, account: account, message_type: :incoming, content: 'Нужен ЛОР') }

    before { create(:message, conversation: conversation, account: account, message_type: :incoming, content: 'Заметка', private: true) }

    it 'answers 202 with a queued state in the shape the dashboard reads' do
      result = service.perform

      expect(result.http_status).to eq(:accepted)
      expect(result.body).to include(
        status: 'queued', reused: false, engine: 'legacy_prompt', conversation_id: conversation.display_id, conversation_record_id: conversation.id,
        started_at: nil, finished_at: nil, deadline_at: nil, duration_ms: nil, stale: false, progress: nil, result: nil,
        budget_seconds: Captain::ReplySuggestion.budget_seconds
      )
      expect(result.body[:suggestion_request_id]).to match(/\A\h{8}(-\h{4}){3}-\h{12}\z/)
      expect(result.body[:created_at]).to match(/\A\d{4}-\d\d-\d\dT\d\d:\d\d:\d\d(\.\d+)?Z\z/)
    end

    it 'stores the request in Redis, points the latest of the user at it, and queues the job on its own queue' do
      expect { service.perform }.to have_enqueued_job(Captain::ReplySuggestion::GenerateJob).on_queue('captain_suggestions')

      id = Captain::ReplySuggestion::RequestStore.latest_id(account.id, agent.id, conversation.id)
      expect(Captain::ReplySuggestion::RequestStore.fetch_raw(id)).to include(
        'status' => 'queued', 'account_id' => account.id, 'user_id' => agent.id, 'conversation_id' => conversation.id,
        'conversation_display_id' => conversation.display_id, 'based_on_message_id' => incoming.id
      )
    end

    it 'queues the job with the id of the request only' do
      service.perform

      id = Captain::ReplySuggestion::RequestStore.latest_id(account.id, agent.id, conversation.id)
      expect(Captain::ReplySuggestion::GenerateJob).to have_been_enqueued.with(id)
    end

    it 'echoes the id the client sent, not the id of the conversation behind a communication thread' do
      thread_service = described_class.new(account: account, user: agent, conversation: conversation, conversation_display_id: '7001')

      expect(thread_service.perform.body).to include(conversation_id: 7001, conversation_record_id: conversation.id)
    end

    it 'takes the account slot and the lock of the user and conversation' do
      service.perform

      expect(Redis::Alfred.zcard(Captain::ReplySuggestion::RequestLocks.account_active_key(account.id))).to eq(1)
      expect(Redis::Alfred.get(Captain::ReplySuggestion::RequestLocks.active_key(account.id, agent.id, conversation.id))).to be_present
    end
  end

  describe 'the engine' do
    it 'is the agent when the account has one that can take the conversation' do
      assistant = create(:captain_assistant, account: account, active: true)

      body = service.perform.body
      record = Captain::ReplySuggestion::RequestStore.fetch_raw(body[:suggestion_request_id])

      expect(body[:engine]).to eq('agent')
      expect(record['assistant_id']).to eq(assistant.id)
    end

    it 'is the old prompt only when the account has no agent: it is then the only engine' do
      create(:captain_assistant, account: account, active: false)

      expect(service.perform.body[:engine]).to eq('legacy_prompt')
    end
  end

  describe 'a request that is already running' do
    it 'reuses it: the same state, reused, and no second job' do
      first = service.perform.body

      expect do
        second = described_class.new(
          account: account, user: agent, conversation: conversation, conversation_display_id: conversation.display_id
        ).perform

        expect(second.http_status).to eq(:accepted)
        expect(second.body).to include(suggestion_request_id: first[:suggestion_request_id], status: 'queued', reused: true)
      end.not_to have_enqueued_job(Captain::ReplySuggestion::GenerateJob)
    end

    it 'reuses a run that is already working' do
      first = service.perform.body
      record = Captain::ReplySuggestion::RequestStore.fetch_raw(first[:suggestion_request_id])
      Captain::ReplySuggestion::RequestStore.mark_running!(record, started_at: Time.current, deadline_at: Time.current + 60)

      expect(service.perform.body).to include(suggestion_request_id: first[:suggestion_request_id], status: 'running', reused: true)
    end

    it 'starts a new run once the previous one has ended' do
      first = service.perform.body
      record = Captain::ReplySuggestion::RequestStore.fetch_raw(first[:suggestion_request_id])
      Captain::ReplySuggestion::RequestStore.finish!(record, status: 'draft', result: { 'message' => 'Привет' })

      second = service.perform.body

      expect(second[:suggestion_request_id]).not_to eq(first[:suggestion_request_id])
      expect(second[:reused]).to be(false)
    end

    it 'does not reuse a run the manager cancelled: that run only waits for its next checkpoint' do
      first = service.perform.body
      record = Captain::ReplySuggestion::RequestStore.fetch_raw(first[:suggestion_request_id])
      Captain::ReplySuggestion::RequestStore.mark_running!(record, started_at: Time.current, deadline_at: Time.current + 60)
      Captain::ReplySuggestion::RequestStore.request_cancel!(first[:suggestion_request_id])

      second = service.perform.body

      expect(second[:suggestion_request_id]).not_to eq(first[:suggestion_request_id])
      expect(second).to include(status: 'queued', reused: false)
    end

    it 'does not share the run between users' do
      first = service.perform.body
      other = create(:user, account: account, role: :agent)

      second = described_class.new(
        account: account, user: other, conversation: conversation, conversation_display_id: conversation.display_id
      ).perform.body

      expect(second[:suggestion_request_id]).not_to eq(first[:suggestion_request_id])
    end
  end

  describe 'the rejections' do
    it 'is 422 voice_channel_unsupported for a voice conversation: no job, no state, one unavailable event' do
      allow(conversation.inbox).to receive(:channel_type).and_return('Channel::Voice')

      result = nil
      expect { result = service.perform }.not_to have_enqueued_job(Captain::ReplySuggestion::GenerateJob)

      expect(result.http_status).to eq(:unprocessable_content)
      expect(result.body).to eq(error: I18n.t('captain.reply_suggestion.errors.voice_channel_unsupported'), error_code: 'voice_channel_unsupported')
      expect(Captain::ReplySuggestion::RequestStore.latest_id(account.id, agent.id, conversation.id)).to be_nil
      expect(unavailable_events.pluck(:reason)).to eq(['voice_channel_unsupported'])
    end

    it 'is 403 disabled when captain tasks are not on' do
      account.disable_features!('captain_tasks')

      result = service.perform

      expect(result.http_status).to eq(:forbidden)
      expect(result.body).to include(error_code: 'disabled')
      expect(unavailable_events.pluck(:reason)).to eq(['disabled'])
    end

    it 'is 422 api_key_missing, not 401: a 401 would log the manager out' do
      allow(Llm::Config).to receive(:api_key).and_return(nil)

      result = service.perform

      expect(result.http_status).to eq(:unprocessable_content)
      expect(result.body).to include(error_code: 'api_key_missing')
    end

    it 'is 429 quota_exceeded when the cloud quota is spent' do
      allow(ChatwootApp).to receive(:chatwoot_cloud?).and_return(true)
      allow(account).to receive(:captain_quota_available?).and_return(false)

      result = service.perform

      expect(result.http_status).to eq(:too_many_requests)
      expect(result.body).to include(error_code: 'quota_exceeded')
    end

    it 'is 429 busy when the account already has the most runs it may have, and gives the lock of the request back' do
      allow(Captain::ReplySuggestion).to receive(:max_active_per_account).and_return(1)
      Redis::Alfred.zadd(Captain::ReplySuggestion::RequestLocks.account_active_key(account.id), Time.current.to_i + 100, 'another-run')

      result = nil
      expect { result = service.perform }.not_to have_enqueued_job(Captain::ReplySuggestion::GenerateJob)

      expect(result.http_status).to eq(:too_many_requests)
      expect(result.body).to include(error_code: 'busy')
      expect(Redis::Alfred.get(Captain::ReplySuggestion::RequestLocks.active_key(account.id, agent.id, conversation.id))).to be_nil
      expect(unavailable_events.pluck(:reason)).to eq(['busy'])
    end

    it 'says it in the language of the account' do
      account.update!(locale: 'ru')
      account.disable_features!('captain_tasks')

      result = I18n.with_locale(:ru) { service.perform }

      expect(result.body[:error]).to eq('ИИ-функции выключены для аккаунта.')
    end

    it 'lets nothing through when the queue is down: the lock and the slot are given back' do
      allow(Captain::ReplySuggestion::GenerateJob).to receive(:perform_later).and_raise(Redis::CannotConnectError)

      expect { service.perform }.to raise_error(Redis::CannotConnectError)

      expect(Redis::Alfred.get(Captain::ReplySuggestion::RequestLocks.active_key(account.id, agent.id, conversation.id))).to be_nil
      expect(Redis::Alfred.zcard(Captain::ReplySuggestion::RequestLocks.account_active_key(account.id))).to eq(0)
    end
  end
end
