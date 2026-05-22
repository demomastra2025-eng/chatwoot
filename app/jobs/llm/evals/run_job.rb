# frozen_string_literal: true

class Llm::Evals::RunJob < ApplicationJob
  SENSITIVE_FRAGMENT = /(api[_-]?key|token|secret|password|authorization|credential)(=|:)?[^\s,;&]*/i
  TERMINAL_STATUSES = %w[passed failed].freeze

  queue_as :low

  def perform(eval_run_id)
    eval_run = ::Llm::EvalRun.find(eval_run_id)
    return unless claim_queued_run!(eval_run)

    result = ::Llm::Evals::Runner.new(
      account: eval_run.account,
      pack_ids: eval_run.pack_ids,
      include_live: true,
      max_cases: eval_run.max_cases
    ).call

    eval_run.update!(
      status: result.passed? ? 'passed' : 'failed',
      result: ::Llm::EvalRun.sanitize_result(result.to_h),
      finished_at: Time.current,
      error_message: nil
    )
  rescue StandardError => e
    eval_run&.update!(
      status: 'failed',
      finished_at: Time.current,
      error_message: sanitized_error(e)
    )
    Rails.logger.warn("LLM eval run #{eval_run&.id || eval_run_id} failed: #{sanitized_error(e)}")
  end

  private

  def claim_queued_run!(eval_run)
    return false if TERMINAL_STATUSES.include?(eval_run.status)

    ::Llm::EvalRun.where(id: eval_run.id, status: 'queued').update_all(
      status: 'running',
      started_at: Time.current,
      error_message: nil,
      updated_at: Time.current
    ) == 1
  end

  def sanitized_error(error)
    "#{error.class.name}: #{error.message}".gsub(SENSITIVE_FRAGMENT) do |match|
      key = match.split(/=|:/, 2).first
      "#{key}=[REDACTED]"
    end
  end
end
