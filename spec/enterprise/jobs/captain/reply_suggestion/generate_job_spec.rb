require 'rails_helper'

RSpec.describe Captain::ReplySuggestion::GenerateJob do
  let(:account) { create(:account) }
  let(:agent) { create(:user, account: account, role: :agent) }
  let(:inbox) { create(:inbox, account: account) }
  let(:conversation) { create(:conversation, account: account, inbox: inbox) }
  let(:store) { Captain::ReplySuggestion::RequestStore }
  let(:outcomes) { Captain::ReplySuggestion::Outcome }
  let(:broadcasts) { [] }
  let(:service_setups) { [] }

  include_context 'with a configured reply suggestion model'

  before do
    Llm::EventSubscriber.install!
    account.enable_features!('captain_integration', 'captain_tasks')
    # The service of the job is a real one; what a spec scripts is done on the instance (any_instance cannot reach the prepended wrapper).
    allow(Captain::ReplySuggestionService).to receive(:new).and_wrap_original do |original, **arguments|
      original.call(**arguments).tap { |service| service_setups.each { |setup| setup.call(service) } }
    end
    allow(ActionCable.server).to receive(:broadcast) { |stream, payload| broadcasts << [stream, payload] }
    create(:message, conversation: conversation, account: account, message_type: :incoming, content: 'Нужен ЛОР на завтра')
  end

  def start_request(**overrides)
    body = Captain::ReplySuggestion::StartService.new(
      account: account, user: agent, conversation: conversation, conversation_display_id: conversation.display_id
    ).perform.body
    id = body[:suggestion_request_id]
    if overrides.any?
      record = store.fetch_raw(id).merge(overrides.stringify_keys)
      Redis::Alfred.set(store.key(id), JSON.generate(record), ex: 600)
    end
    id
  end

  def run_job(id)
    described_class.perform_now(id)
    store.fetch_raw(id)
  end

  def on_service(&setup)
    service_setups << setup
  end

  # What the service does in the job: the scripted run (the rest of the service is real).
  def script_run(&)
    script = proc(&)
    on_service { |service| allow(service).to receive(:perform, &script) }
  end

  def outcome_events(id)
    LlmEvent.where(event_name: 'captain.reply_suggestion.complete', request_id: id)
  end

  def feedback_events(id, status)
    LlmEvent.where(event_name: 'llm.copilot.feedback', request_id: id, status: status)
  end

  def result_broadcasts
    broadcasts.select { |_stream, payload| payload[:event] == 'captain.reply_suggestion.result' }
  end

  def draft_outcome(**extra)
    outcomes.draft(message: 'Здравствуйте! Ближайшее окно завтра в 10:00.', engine: 'agent', agent: { 'id' => 84, 'name' => 'Сезім' },
                   usage: { 'total_tokens' => 150 }, **extra)
  end

  describe 'a draft' do
    before do
      script_run do
        sleep 0.02
        draft_outcome
      end
    end

    it 'goes queued, running, draft and records the text, the duration and the agent' do
      id = start_request
      expect(store.fetch_raw(id)['status']).to eq('queued')

      record = run_job(id)

      expect(record).to include('status' => 'draft', 'reason_code' => nil)
      expect(record['duration_ms']).to be_positive
      expect(record['started_at']).to be_present
      expect(record['deadline_at']).to be_present
      expect(record['result']).to include('message' => 'Здравствуйте! Ближайшее окно завтра в 10:00.', 'agent' => { 'id' => 84, 'name' => 'Сезім' })
    end

    it 'broadcasts a start and exactly one result, only to the pubsub stream of the manager who asked' do
      id = start_request

      run_job(id)

      expect(broadcasts.map(&:first).uniq).to eq([agent.pubsub_token])
      expect(broadcasts.first.last).to include(event: 'captain.reply_suggestion.progress', data: hash_including(
        suggestion_request_id: id, status: 'running', phase: 'starting', conversation_id: conversation.display_id, budget_seconds: 60, elapsed_ms: 0
      ))
      expect(result_broadcasts.size).to eq(1)
      expect(result_broadcasts.first.last[:data]).to include(
        suggestion_request_id: id, status: 'draft', result: hash_including('message' => 'Здравствуйте! Ближайшее окно завтра в 10:00.')
      )
    end

    it 'records the generated feedback with the id of the request, and one outcome event with the real duration and the wait in the queue' do
      id = start_request
      run_job(id)

      expect(feedback_events(id, 'generated').count).to eq(1)
      expect(feedback_events(id, 'generated').first.payload).to include('generated_reply_preview' => 'Здравствуйте! Ближайшее окно завтра в 10:00.')
      event = outcome_events(id).sole
      expect(event).to have_attributes(
        status: 'draft', error: false, feature: 'reply_suggestion', source: 'reply_suggestion', account_id: account.id,
        conversation_id: conversation.id, runtime_mode: 'captain_task'
      )
      expect(event.duration_ms).to be_positive
      expect(event.queue_wait_ms).to be >= 0
      expect(event.payload).to include('outcome' => 'draft', 'engine' => 'legacy_prompt', 'budget_ms' => 60_000, 'stale' => false)
    end

    it 'frees the lock and the slot of the request' do
      id = start_request
      run_job(id)

      expect(Redis::Alfred.get(Captain::ReplySuggestion::RequestLocks.active_key(account.id, agent.id, conversation.id))).to be_nil
      expect(Redis::Alfred.zcard(Captain::ReplySuggestion::RequestLocks.account_active_key(account.id))).to eq(0)
    end

    it 'makes the agent of the draft the sticky agent of the dialog for the next suggestions' do
      id = start_request
      run_job(id)

      expect(Captain::ReplySuggestion::StickyAgent.read(conversation)).to eq(84)
    ensure
      Captain::ReplySuggestion::StickyAgent.keys_for(conversation).each { |key| Redis::Alfred.delete(key) }
    end

    it 'runs as the manager, in the language of the account' do
      account.update!(locale: 'ru')
      seen = {}
      script_run do
        seen.merge!(user: Current.user, locale: I18n.locale, request_id: Llm::EventBus.request_id)
        draft_outcome
      end
      id = start_request

      run_job(id)

      expect(seen).to eq(user: agent, locale: :ru, request_id: id)
    end
  end

  describe 'no reply and a person must answer' do
    it 'ends as no_reply with the reason for the manager, and counts the tokens but not a response' do
      script_run do
        outcomes.no_reply(
          reason: 'Пациент только поблагодарил.', engine: 'agent', agent: { 'id' => 84, 'name' => 'Сезім' }, usage: { 'total_tokens' => 40 }
        )
      end
      id = start_request

      record = run_job(id)

      expect(record).to include('status' => 'no_reply')
      expect(record['result']).to include('reason' => 'Пациент только поблагодарил.', 'reason_source' => 'agent')
      expect(record['result']).not_to have_key('message')
      expect(account.reload.captain_tokens_usage).to eq(40)
      expect(feedback_events(id, 'generated')).to be_empty
      expect(outcome_events(id).sole).to have_attributes(status: 'no_reply', reason: 'agent', error: false)
      expect(outcome_events(id).sole.payload).to include('reason_preview' => 'Пациент только поблагодарил.')
    end

    it 'leaves the sticky agent as it was when the router sent the turn to staff' do
      Captain::ReplySuggestion::StickyAgent.remember!(conversation, 119)
      script_run { outcomes.human_needed(reason: 'Пациент просит сотрудника.', engine: 'agent', reason_source: 'router', agent: nil) }

      run_job(start_request)

      expect(Captain::ReplySuggestion::StickyAgent.read(conversation)).to eq(119)
    ensure
      Captain::ReplySuggestion::StickyAgent.keys_for(conversation).each { |key| Redis::Alfred.delete(key) }
    end

    it 'ends as human_needed with the reason for the manager' do
      script_run { outcomes.human_needed(reason: 'В базе нет ответа, решает врач.', engine: 'agent', reason_source: 'agent') }
      id = start_request

      record = run_job(id)

      expect(record).to include('status' => 'human_needed')
      expect(record['result']).to include('reason' => 'В базе нет ответа, решает врач.', 'reason_source' => 'agent', 'pending_actions' => [])
      expect(outcome_events(id).sole).to have_attributes(status: 'human_needed', reason: 'agent')
      expect(result_broadcasts.first.last[:data]).to include(status: 'human_needed')
    end
  end

  describe 'a run that does not finish' do
    it 'fails with timeout when the budget is spent at a checkpoint, and leaves no draft and no text' do
      script_run do
        sleep 1.1
        Captain::ReplySuggestion::RunControl.checkpoint!(:turn)
        draft_outcome
      end
      id = start_request(budget_seconds: 1)

      record = run_job(id)

      expect(record).to include('status' => 'failed', 'reason_code' => 'timeout', 'result' => { 'reason_code' => 'timeout' })
      expect(outcome_events(id).sole).to have_attributes(status: 'failed', error: true, error_code: 'timeout')
      expect(outcome_events(id).sole.payload).to include('stage' => 'turn', 'detail' => 'deadline_at_turn')
      expect(feedback_events(id, 'generated')).to be_empty
      expect(result_broadcasts.first.last[:data]).to include(status: 'failed', result: { 'reason_code' => 'timeout' })
    end

    it 'fails with timeout when a call hangs: the safety net cuts it, nothing partial is kept' do
      stub_const("#{Captain::ReplySuggestion}::HARD_GRACE_SECONDS", 0)
      script_run { sleep 5 }
      id = start_request(budget_seconds: 1)

      started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      record = run_job(id)

      expect(Process.clock_gettime(Process::CLOCK_MONOTONIC) - started).to be < 3
      expect(record).to include('status' => 'failed', 'reason_code' => 'timeout')
      expect(outcome_events(id).sole.payload).to include('detail' => 'hard_limit')
    end

    it 'fails with internal_error on an unexpected error, and does not raise' do
      script_run { raise ArgumentError, 'boom' }
      id = start_request

      expect { described_class.perform_now(id) }.not_to raise_error

      expect(store.fetch_raw(id)).to include('status' => 'failed', 'reason_code' => 'internal_error')
      expect(outcome_events(id).sole.payload).to include('error_class' => 'ArgumentError')
    end

    it 'turns a failure of the service into a failure whatever its code' do
      script_run { outcomes.failed('provider_error', error_class: 'RubyLLM::ServerError') }
      id = start_request

      expect(run_job(id)).to include('status' => 'failed', 'reason_code' => 'provider_error')
    end

    it 'maps the answer of the task wrapper to a failure instead of drafting from it' do
      script_run { { error: 'Лимит', error_code: 429 } }
      id = start_request

      expect(run_job(id)).to include('status' => 'failed', 'reason_code' => 'quota_exceeded')
    end

    it 'discards the approval cards the failed run prepared, and only those' do
      older = Captain::ReplySuggestion::ActionApprovalService.store_record!(
        'action_id' => 'older-card', 'account_id' => account.id, 'conversation_id' => conversation.id, 'status' => 'pending'
      )
      script_run do
        Captain::ReplySuggestion::ActionApprovalService.store_record!(
          'action_id' => 'run-card', 'account_id' => account.id, 'conversation_id' => conversation.id, 'status' => 'pending'
        )
        outcomes.failed('tool_failure')
      end
      id = start_request

      run_job(id)

      expect(Captain::ReplySuggestion::ActionApprovalService.fetch_record('run-card'))
        .to include('status' => 'rejected', 'rejected_reason' => 'suggestion_run_aborted')
      expect(Captain::ReplySuggestion::ActionApprovalService.fetch_record(older['action_id'])).to include('status' => 'pending')
    end

    it 'keeps the cards of a draft' do
      script_run do
        Captain::ReplySuggestion::ActionApprovalService.store_record!(
          'action_id' => 'draft-card', 'account_id' => account.id, 'conversation_id' => conversation.id, 'status' => 'pending'
        )
        draft_outcome
      end
      id = start_request

      run_job(id)

      expect(Captain::ReplySuggestion::ActionApprovalService.fetch_record('draft-card')).to include('status' => 'pending')
    end

    it 'does not run again: a failure is not retried' do
      script_run { raise ArgumentError, 'boom' }
      id = start_request

      expect { described_class.perform_now(id) }.not_to have_enqueued_job(described_class)
    end
  end

  describe 'a cancel' do
    it 'before the start: ends cancelled without running anything, with its event' do
      id = start_request
      store.request_cancel!(id)
      expect(Captain::ReplySuggestionService).not_to receive(:new)

      record = run_job(id)

      expect(record).to include('status' => 'cancelled', 'result' => nil)
      expect(outcome_events(id).sole).to have_attributes(status: 'cancelled', reason: 'user', error: false)
      expect(result_broadcasts.size).to eq(1)
    end

    it 'during the run: stops at the next checkpoint, discards the cards of the run, and records no draft' do
      Captain::ReplySuggestion::ActionApprovalService.store_record!(
        'action_id' => 'cancel-card', 'account_id' => account.id, 'conversation_id' => conversation.id, 'status' => 'pending'
      )
      id = start_request
      script_run do
        Captain::ReplySuggestion::RunControl.register_action('cancel-card')
        store.request_cancel!(id)
        sleep Captain::ReplySuggestion::CANCEL_CHECK_INTERVAL + 0.05
        Captain::ReplySuggestion::RunControl.checkpoint!(:tool)
        draft_outcome
      end

      record = run_job(id)

      expect(record).to include('status' => 'cancelled', 'result' => nil)
      expect(Captain::ReplySuggestion::ActionApprovalService.fetch_record('cancel-card')).to include('status' => 'rejected')
      expect(feedback_events(id, 'generated')).to be_empty
      expect(outcome_events(id).sole).to have_attributes(status: 'cancelled', reason: 'user')
      expect(outcome_events(id).sole.payload).to include('stage' => 'tool')
    end

    it 'after the last checkpoint: a run that completes but was cancelled is cancelled all the same' do
      id = start_request
      script_run do
        store.request_cancel!(id)
        draft_outcome
      end

      record = run_job(id)

      expect(record).to include('status' => 'cancelled')
      expect(outcome_events(id).sole).to have_attributes(status: 'cancelled')
      expect(feedback_events(id, 'generated')).to be_empty
    end
  end

  describe 'a request that cannot run' do
    it 'fails with queue_timeout when it waited too long in the queue, and runs nothing' do
      id = start_request(created_at: (Time.current - 120).utc.iso8601(3))
      expect(Captain::ReplySuggestionService).not_to receive(:new)

      record = run_job(id)

      expect(record).to include('status' => 'failed', 'reason_code' => 'queue_timeout')
      expect(outcome_events(id).sole).to have_attributes(status: 'failed', error_code: 'queue_timeout')
      expect(outcome_events(id).sole.queue_wait_ms).to be >= 100_000
    end

    it 'does nothing for a request whose state has expired' do
      expect(Captain::ReplySuggestionService).not_to receive(:new)

      expect { described_class.perform_now(SecureRandom.uuid) }.not_to raise_error
      expect(broadcasts).to be_empty
    end

    it 'does nothing for a request that has finished: a second delivery does not make a second answer' do
      script_run { draft_outcome }
      id = start_request
      run_job(id)
      broadcasts.clear
      expect(Captain::ReplySuggestionService).not_to receive(:new)

      run_job(id)

      expect(broadcasts).to be_empty
      expect(outcome_events(id).count).to eq(1)
    end

    it 'fails with interrupted when a delivery finds the request still running: the worker that ran it died' do
      id = start_request
      store.mark_running!(store.fetch_raw(id), started_at: Time.current, deadline_at: Time.current + 60)
      expect(Captain::ReplySuggestionService).not_to receive(:new)

      record = run_job(id)

      expect(record).to include('status' => 'failed', 'reason_code' => 'interrupted')
      expect(outcome_events(id).sole).to have_attributes(status: 'failed', error_code: 'interrupted')
    end

    it 'fails with interrupted when the worker is shut down in the middle of the run, still with one event' do
      id = start_request
      script_run { raise Sidekiq::Shutdown }

      expect { described_class.perform_now(id) }.to raise_error(Sidekiq::Shutdown)

      expect(store.fetch_raw(id)).to include('status' => 'failed', 'reason_code' => 'interrupted')
      expect(outcome_events(id).sole).to have_attributes(status: 'failed', error_code: 'interrupted')
      expect(result_broadcasts.size).to eq(1)
      expect(Redis::Alfred.get(Captain::ReplySuggestion::RequestLocks.active_key(account.id, agent.id, conversation.id))).to be_nil
    end

    it 'fails when the conversation is gone' do
      id = start_request
      conversation.destroy!

      expect(run_job(id)).to include('status' => 'failed', 'reason_code' => 'internal_error')
    end
  end

  describe 'with the real service' do
    let(:runner) { instance_double(Captain::Assistant::AgentRunnerService) }
    let(:legacy_prompt_calls) { [] }

    before do
      on_service do |service|
        allow(service).to receive(:make_api_call) do |**arguments|
          legacy_prompt_calls << arguments
          { message: 'Ответ старого промпта', usage: {} }
        end
      end
      allow(Captain::Assistant::AgentRunnerService).to receive(:new).and_return(runner)
    end

    context 'when the account has an agent' do
      let!(:assistant) { create(:captain_assistant, account: account, name: 'Сезім', active: true) }

      def agent_answers(payload)
        allow(runner).to receive(:generate_response).and_return({ 'agent_id' => assistant.id, 'agent_display_name' => assistant.name }.merge(payload))
      end

      it 'drafts from the agent, counts a response, and gives the id of the request to the agent run' do
        agent_answers('response' => 'Здравствуйте!', 'response_mode' => 'reply', 'usage' => { 'total_tokens' => 70 })
        id = start_request

        record = run_job(id)

        expect(record).to include('status' => 'draft', 'engine' => 'agent')
        expect(record['result']).to include('message' => 'Здравствуйте!', 'agent' => hash_including('name' => 'Сезім'))
        expect(Captain::Assistant::AgentRunnerService).to have_received(:new).with(hash_including(request_id: id, source: 'reply_suggestion'))
        expect(outcome_events(id).sole).to have_attributes(runtime_mode: 'captain_runtime', status: 'draft')
        expect(outcome_events(id).sole.payload).to include('engine' => 'agent')
      end

      it 'never runs the old one-shot prompt when the agent does not finish in time' do
        allow(runner).to receive(:generate_response) do
          sleep 1.1
          Captain::ReplySuggestion::RunControl.checkpoint!(:turn)
          { 'response' => 'Текст, который нельзя показывать', 'response_mode' => 'reply' }
        end
        id = start_request(budget_seconds: 1)

        record = run_job(id)

        expect(record).to include('status' => 'failed', 'reason_code' => 'timeout')
        expect(record['result']).to eq('reason_code' => 'timeout')
        expect(legacy_prompt_calls).to be_empty
      end

      it 'never runs the old one-shot prompt when the agent fails, is stopped, or has nothing to say' do
        [
          { 'response' => Captain::Assistant::AgentRunnerService::PROVIDER_ERROR_RESPONSE, 'error_class' => 'RubyLLM::ServerError' },
          { 'response' => 'conversation_handoff' },
          { 'response' => '', 'response_mode' => 'suppress', 'response_suppressed' => true, 'operator_note' => '' },
          { 'response' => '   ', 'response_mode' => 'reply' }
        ].each do |payload|
          agent_answers(payload)
          expect(run_job(start_request)).to include('status' => 'failed')
        end

        expect(legacy_prompt_calls).to be_empty
      end

      it 'never runs the old one-shot prompt when the agent raises a timeout' do
        allow(runner).to receive(:generate_response).and_raise(Timeout::Error)
        id = start_request

        expect(run_job(id)).to include('status' => 'failed', 'reason_code' => 'timeout')
        expect(legacy_prompt_calls).to be_empty
      end

      it 'fails with agent_unavailable when the agent was deleted after the request started, and does not run the old prompt' do
        id = start_request
        assistant.destroy!

        expect(run_job(id)).to include('status' => 'failed', 'reason_code' => 'agent_unavailable')
        expect(legacy_prompt_calls).to be_empty
        expect(Captain::Assistant::AgentRunnerService).not_to have_received(:new)
      end

      it 'tells the manager why nobody should write, and what a person has to answer, in the language of the account' do
        account.update!(locale: 'ru')
        agent_answers('response' => '', 'response_mode' => 'suppress', 'response_suppressed' => true, 'operator_note' => 'Только благодарность.')
        no_reply = run_job(start_request)

        agent_answers('response' => 'conversation_handoff', 'moderation_blocked' => true, 'safety_reason' => 'prompt_injection')
        blocked = run_job(start_request)

        expect(no_reply).to include('status' => 'no_reply')
        expect(no_reply['result']['reason']).to eq('Только благодарность.')
        expect(blocked).to include('status' => 'human_needed')
        expect(blocked['result']).to include(
          'reason' => 'Проверка безопасности остановила ответ ИИ — ответьте клиенту сами.', 'reason_source' => 'safety'
        )
      end
    end

    context 'when the account has no agent' do
      it 'drafts with the old prompt, the only engine, and says so' do
        id = start_request

        record = run_job(id)

        expect(record).to include('status' => 'draft', 'engine' => 'legacy_prompt')
        expect(record['result']['message']).to eq('Ответ старого промпта')
        expect(Captain::Assistant::AgentRunnerService).not_to have_received(:new)
        expect(outcome_events(id).sole).to have_attributes(runtime_mode: 'captain_task')
      end

      it 'does not let an agent created after the request took over: the engine is fixed at the start' do
        id = start_request
        create(:captain_assistant, account: account, active: true)

        expect(run_job(id)).to include('engine' => 'legacy_prompt')
        expect(Captain::Assistant::AgentRunnerService).not_to have_received(:new)
      end

      it 'fails a cancelled-in-flight prompt as cancelled, not as a draft' do
        id = start_request
        on_service do |service|
          allow(service).to receive(:make_api_call) do
            store.request_cancel!(id)
            { message: 'Ответ старого промпта', usage: {} }
          end
        end

        expect(run_job(id)).to include('status' => 'cancelled')
      end
    end
  end
end
