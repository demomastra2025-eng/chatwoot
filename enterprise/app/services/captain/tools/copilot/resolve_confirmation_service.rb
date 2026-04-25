# frozen_string_literal: true

class Captain::Tools::Copilot::ResolveConfirmationService < Captain::Tools::Copilot::BaseAccountTool
  def self.name
    'resolve_confirmation'
  end

  description 'Resolve a universal confirmation request as confirmed, declined, or reschedule_requested with audit source metadata'
  param :confirmation_request_id, type: :number, desc: 'Confirmation request ID to resolve', required: true
  param :decision, type: :string, desc: 'Decision: confirmed, declined, or reschedule_requested', required: true
  param :source, type: :string, desc: 'Resolution source: manual, ai, text, button, link, or system', required: true
  param :confidence, type: :number, desc: 'Optional AI/text classifier confidence from 0.0 to 1.0', required: false
  param :metadata, type: :object, desc: 'Optional structured resolution metadata', required: false

  def execute(confirmation_request_id:, decision:, source:, confidence: nil, metadata: {})
    request = confirmation_operations.resolve_confirmation(
      confirmation_request_id: confirmation_request_id,
      decision: decision,
      source: source,
      confidence: confidence,
      metadata: metadata
    )

    formatted_payload(
      action: 'resolve_confirmation',
      confirmation_request: Confirmations::PayloadBuilder.confirmation_request(request)
    )
  rescue StandardError => e
    tool_failure(e)
  end

  private

  def confirmation_operations
    Captain::Tools::Operations::ConfirmationOperations.new(
      assistant: assistant,
      conversation: current_conversation,
      actor: @user
    )
  end
end
