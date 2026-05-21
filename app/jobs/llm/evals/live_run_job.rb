# frozen_string_literal: true

class Llm::Evals::LiveRunJob < ApplicationJob
  SENSITIVE_FRAGMENT = /(api[_-]?key|token|secret|password|authorization|credential)(=|:)?[^\s,;&]*/i

  queue_as :low

  def perform(eval_run_id)
    eval_run = ::Llm::EvalRun.find(eval_run_id)
    eval_run.update!(status: 'running', started_at: Time.current, error_message: nil)

    result = ::Llm::Evals::Runner.new(
      account: eval_run.account,
      pack_ids: eval_run.pack_ids,
      include_live: true,
      max_cases: eval_run.max_cases
    ).call

    eval_run.update!(
      status: result.passed? ? 'passed' : 'failed',
      result: result.to_h,
      finished_at: Time.current,
      error_message: nil
    )
  rescue StandardError => e
    eval_run&.update!(
      status: 'failed',
      finished_at: Time.current,
      error_message: sanitized_error(e)
    )
    raise
  end

  private

  def sanitized_error(error)
    "#{error.class.name}: #{error.message}".gsub(SENSITIVE_FRAGMENT) do |match|
      key = match.split(/=|:/, 2).first
      "#{key}=[REDACTED]"
    end
  end
end
