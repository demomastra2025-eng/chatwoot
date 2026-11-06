# frozen_string_literal: true

class Llm::PiiShadowAuditJob < ApplicationJob
  queue_as :low
  if respond_to?(:retry_on) && defined?(Llm::OpenRouterDecisionClient::Error)
    retry_on Llm::OpenRouterDecisionClient::Error, wait: 2.seconds,
                                                   attempts: 2
  end

  retry_on Llm::PiiShadowAuditor::StorageUnavailable, wait: 2.seconds, attempts: 2 if respond_to?(:retry_on)

  def perform(masked_text, account_id: nil, raise_on_transient: true)
    return { status: :disabled, missed: nil, learned: [], quarantined: [] } unless Llm::PiiShadowAuditor.shadow_audit_enabled?

    Llm::PiiShadowAuditor.audit_masked_message!(
      masked_text,
      account_id: account_id,
      raise_on_transient: raise_on_transient
    )
  end
end
