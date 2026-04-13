# frozen_string_literal: true

class Internal::BackfillLlmEventTraceIdJob < ApplicationJob
  queue_as :scheduled_jobs

  def perform
    summary = Llm::Monitoring::TraceBackfill.new.call
    Rails.logger.info("[Internal::BackfillLlmEventTraceIdJob] #{summary}")
  end
end
