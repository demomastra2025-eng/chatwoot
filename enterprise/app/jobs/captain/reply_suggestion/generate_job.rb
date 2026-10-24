# frozen_string_literal: true

require 'timeout'

# Makes a reply suggestion in the background ("Предложить ответ"). StartService creates the request in Redis and queues this job; the
# manager sees live progress over ActionCable and gets the result as one `captain.reply_suggestion.result` event.
#
# The run has a budget (60 s by default, from the start of the job). It either finishes or ends as `failed`: a run that did not finish
# leaves no draft, whatever it had collected, and an account that has an agent never gets the old one-shot prompt instead.
#
# Never retried: a second run after the manager has moved on would be a second answer. #perform does not raise: every end is an outcome.
class Captain::ReplySuggestion::GenerateJob < ApplicationJob
  queue_as Captain::ReplySuggestion::QUEUE_NAME
  discard_on StandardError do |job, error|
    Rails.logger.error("[CAPTAIN][ReplySuggestion] #{job.class.name} discarded: #{error.class}: #{error.message}")
  end

  Outcome = Captain::ReplySuggestion::Outcome
  OutcomeEvent = Captain::ReplySuggestion::OutcomeEvent
  RequestStore = Captain::ReplySuggestion::RequestStore

  def perform(request_id)
    @request_id = request_id
    @state = RequestStore.fetch_raw(request_id)
    process if @state
  ensure
    # Sidekiq::Shutdown is not a StandardError: a run killed by a deploy still ends as failed{interrupted}.
    finish_run(@outcome || Outcome.failed('interrupted')) if @running && !@finished
    Captain::ReplySuggestion::RequestLocks.release!(@state) if @state
  end

  private

  def process
    case @state['status']
    when 'queued' then run_queued
    when 'running' then finish_run(Outcome.failed('interrupted')) # redelivered after the worker that ran it died
    end
  end

  def run_queued
    return finish_run(Outcome.cancelled) if RequestStore.cancel_requested?(@request_id)
    return finish_run(Outcome.failed('queue_timeout')) if seconds_since(@state['created_at']) > Captain::ReplySuggestion::MAX_QUEUE_WAIT_SECONDS
    return finish_run(Outcome.failed('internal_error', detail: 'records_missing')) if account.nil? || user.nil? || conversation.nil?

    run
  end

  def run
    budget = @state['budget_seconds'].to_i
    started_at = Time.current
    @started_monotonic = monotonic_now
    @state = RequestStore.mark_running!(@state, started_at: started_at, deadline_at: started_at + budget)
    @running = true
    broadcaster.progress(starting_progress)

    run_and_publish(@started_monotonic + budget, budget)
    finish_run(@outcome)
  end

  # The outcome event is published around the run (block form), so that its duration is the duration of the run.
  def run_and_publish(deadline, budget)
    Llm::EventBus.publish(OutcomeEvent::EVENT, OutcomeEvent.base_payload(@state, conversation: conversation)) do |event|
      @event_published = true
      begin
        @outcome = final_gate(run_with_controls(deadline, budget))
      ensure
        # Without an outcome an exception that is not a StandardError (Sidekiq::Shutdown) ended the run.
        @outcome ||= Outcome.failed('interrupted')
        OutcomeEvent.fill!(event, @state, @outcome, stats: run_stats)
      end
    end
  end

  def run_with_controls(deadline, budget)
    with_run_context do
      Timeout.timeout(budget + Captain::ReplySuggestion::HARD_GRACE_SECONDS) do
        Captain::ReplySuggestion::RunControl.with(request_id: @request_id, deadline: deadline) do |control|
          @control = control
          Outcome.normalize(service.perform)
        end
      end
    end
  rescue Captain::ReplySuggestion::RunAborted => e
    aborted_outcome(e)
  rescue Timeout::Error
    Outcome.failed('timeout', detail: 'hard_limit')
  rescue StandardError => e
    Rails.logger.warn("[CAPTAIN][ReplySuggestion] request=#{@request_id} run failed: #{e.class}: #{e.message}")
    Outcome.failed('internal_error', error_class: e.class.name, detail: e.message.to_s.truncate(200))
  end

  def aborted_outcome(error)
    return Outcome.cancelled(stage: error.stage) if error.kind == :cancelled

    Outcome.failed('timeout', detail: "deadline_at_#{error.stage}", stage: error.stage)
  end

  # A run that finished between the last checkpoint and the cancel is cancelled all the same: the manager does not want it.
  def final_gate(outcome)
    return Outcome.cancelled if outcome[:outcome] != 'cancelled' && RequestStore.cancel_requested?(@request_id)

    outcome
  end

  def finish_run(outcome)
    @finished = true
    publish_outcome_event(outcome) unless @event_published
    record = RequestStore.finish!(@state, status: outcome[:outcome], result: Outcome.public_result(outcome),
                                          reason_code: Outcome.reason_code(outcome), duration_ms: run_duration_ms)
    @state = record
    apply_side_effects(outcome)
    broadcaster.result(record)
  end

  # A request that never ran (cancelled or lost in the queue, or killed) has its event too: exactly one per request.
  def publish_outcome_event(outcome)
    @event_published = true
    OutcomeEvent.publish_finished(@state, outcome, conversation: conversation, stats: run_stats)
  rescue StandardError => e
    Rails.logger.warn("[CAPTAIN][ReplySuggestion] outcome event skipped: #{e.class}: #{e.message}")
  end

  def apply_side_effects(outcome)
    case outcome[:outcome]
    when 'draft' then record_generated(outcome)
    when 'no_reply', 'human_needed' then count_tokens(outcome)
    else discard_run_actions
    end
  rescue StandardError => e
    Rails.logger.warn("[CAPTAIN][ReplySuggestion] side effects of #{outcome[:outcome]} skipped: #{e.class}: #{e.message}")
  end

  def record_generated(outcome)
    Captain::CopilotFeedbackRecorder.record!(
      account: account, user: user, conversation: conversation, requested_display_id: @state['conversation_display_id'],
      outcome: 'generated', copilot_action: 'reply_suggestion', request_id: @request_id, suggestion_request_id: @request_id,
      generated_text: outcome[:message], extra: { engine: @state['engine'], based_on_message_id: @state['based_on_message_id'] }.compact
    )
  end

  # A response credit is counted only for a draft (by the task wrapper); the tokens of the other answers are still spent.
  def count_tokens(outcome)
    total = outcome[:usage].to_h.with_indifferent_access[:total_tokens].to_i
    account.increment_token_usage(total) if total.positive?
  end

  # No partial results: the approval cards the run prepared go with it.
  def discard_run_actions
    Captain::ReplySuggestion::ActionApprovalService.discard!(action_ids: @control&.action_ids, reason: 'suggestion_run_aborted')
  end

  # The run is made as the manager who asked, in the language of the account.
  def with_run_context(&)
    previous = [Current.user, Current.account, Current.account_user]
    Current.user = user
    Current.account = account
    Current.account_user = account.account_users.find_by(user_id: user.id)
    I18n.with_locale(account_locale) do
      Llm::EventBus.with_context(user_id: user.id, request_id: @request_id, &)
    end
  ensure
    Current.user, Current.account, Current.account_user = previous
  end

  # (not `locale`: ActiveJob has a #locale of its own)
  def account_locale
    account.locale.to_s.presence_in(I18n.available_locales.map(&:to_s)) || I18n.default_locale
  end

  def service
    @service ||= Captain::ReplySuggestionService.new(
      account: account, conversation_display_id: @state['conversation_display_id'], user: user, conversation: conversation,
      request_id: @request_id, engine: @state['engine'], assistant_id: @state['assistant_id'], progress_context: progress_context
    )
  end

  def progress_context
    {
      suggestion_request_id: @request_id, conversation_id: @state['conversation_display_id'],
      started_at: Time.zone.parse(@state['started_at']), deadline_at: Time.zone.parse(@state['deadline_at']),
      budget_seconds: @state['budget_seconds']
    }
  end

  def starting_progress
    {
      suggestion_request_id: @request_id, status: 'running', account_id: account.id, conversation_id: @state['conversation_display_id'],
      conversation_record_id: conversation.id, started_at: @state['started_at'], deadline_at: @state['deadline_at'],
      budget_seconds: @state['budget_seconds'], elapsed_ms: 0, phase: 'starting'
    }
  end

  def run_stats
    @service&.run_stats || {}
  end

  def run_duration_ms
    ((monotonic_now - @started_monotonic) * 1000).round if @started_monotonic
  end

  def broadcaster
    @broadcaster ||= Captain::ReplySuggestion::Broadcaster.new(user: user)
  end

  def account
    @account ||= Account.find_by(id: @state['account_id'])
  end

  def user
    @user ||= User.find_by(id: @state['user_id'])
  end

  def conversation
    @conversation ||= Conversation.find_by(id: @state['conversation_id'], account_id: @state['account_id'])
  end

  def seconds_since(iso_time)
    Time.current - Time.zone.parse(iso_time)
  end

  def monotonic_now
    Process.clock_gettime(Process::CLOCK_MONOTONIC)
  end
end
