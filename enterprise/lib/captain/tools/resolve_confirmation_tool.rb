# frozen_string_literal: true

class Captain::Tools::ResolveConfirmationTool < Captain::Tools::BasePublicTool
  description 'Resolve a universal confirmation request as confirmed, declined, or reschedule_requested with audit source metadata'
  param :confirmation_request_id, type: 'number', desc: 'Confirmation request ID to resolve', required: true
  param :decision, type: 'string', desc: 'Decision: confirmed, declined, or reschedule_requested', required: true
  param :source, type: 'string', desc: 'Resolution source: ai, text, button, link, manual, or system', required: true
  param :confidence, type: 'number', desc: 'Optional AI/text classifier confidence from 0.0 to 1.0', required: false
  param :metadata, type: 'object', desc: 'Optional structured resolution metadata', required: false

  # rubocop:disable Metrics/ParameterLists
  def perform(tool_context, confirmation_request_id:, decision:, source:, confidence: nil, metadata: {})
    request = operations(tool_context.state).resolve_confirmation(
      confirmation_request_id: confirmation_request_id,
      decision: decision,
      source: source,
      confidence: confidence,
      metadata: metadata
    )

    JSON.pretty_generate(
      action: 'resolve_confirmation',
      confirmation_request: Confirmations::PayloadBuilder.confirmation_request(request)
    )
  rescue StandardError => e
    tool_failure(e)
  end
  # rubocop:enable Metrics/ParameterLists

  private

  def operations(state)
    Captain::Tools::Operations::ConfirmationOperations.new(
      assistant: assistant,
      conversation: current_conversation(state)
    )
  end
end
