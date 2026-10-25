# frozen_string_literal: true

# The timing of a reply suggestion run as the manager sees it (GenerateJob): the progress context the run reports from, the first
# progress event, and the real deadline once the router gave the run the budget of one agent (RunControl#shorten!).
module Captain::ReplySuggestion::RunTiming
  private

  # The router gave the run the budget of one agent (RunControl#shorten!, on the thread of the run): the request record, the
  # progress the run broadcasts and the manager's timer and watchdog get the real deadline and budget.
  def deadline_shortened(deadline)
    deadline_at = Time.current + (deadline - monotonic_now)
    budget = (deadline - @started_monotonic).ceil
    @state = Captain::ReplySuggestion::RequestStore.reschedule!(@state, deadline_at: deadline_at, budget_seconds: budget)
    progress_context.merge!(deadline_at: deadline_at, budget_seconds: budget)
    broadcaster.progress(starting_progress.except(:phase).merge(elapsed_ms: run_duration_ms))
  rescue StandardError => e
    Rails.logger.warn("[CAPTAIN][ReplySuggestion] request=#{@request_id} new deadline not published: #{e.class}: #{e.message}")
  end

  # One hash for the whole run: the service reads its timing from it, and a shortened deadline updates it (#deadline_shortened).
  def progress_context
    @progress_context ||= {
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
end
