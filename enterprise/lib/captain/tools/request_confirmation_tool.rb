# frozen_string_literal: true

class Captain::Tools::RequestConfirmationTool < Captain::Tools::BasePublicTool
  description(
    'Create a universal confirmation request in the current conversation, optionally bound to current appointment, deal, task, or conversation'
  )
  param :title, type: 'string', desc: 'Short confirmation title shown to the customer', required: true
  param :body, type: 'string', desc: 'Confirmation message body shown to the customer', required: true
  param(
    :subject_kind,
    type: 'string',
    desc: 'Optional current-context subject: conversation, appointment, deal, or task. Omit for standalone',
    required: false
  )
  param :expires_at, type: 'string', desc: 'Optional expiration datetime in ISO 8601 format', required: false
  param :send_now, type: 'boolean', desc: 'Whether to immediately send a channel-aware confirmation message. Defaults to true', required: false
  param :metadata, type: 'object', desc: 'Optional structured metadata for this confirmation request', required: false
  param :idempotency_key, type: 'string', desc: 'Optional account-scoped idempotency key to avoid duplicate pending requests', required: false

  # rubocop:disable Metrics/ParameterLists
  def perform(tool_context, title:, body:, subject_kind: nil, expires_at: nil, send_now: true, metadata: {}, idempotency_key: nil)
    request, delivery_message, delivery_error = operations(tool_context.state).request_confirmation(
      title: title,
      body: body,
      subject: subject_from_state(tool_context.state, subject_kind),
      expires_at: expires_at,
      send_now: ActiveModel::Type::Boolean.new.cast(send_now),
      metadata: metadata,
      idempotency_key: idempotency_key
    )

    payload = {
      action: 'request_confirmation',
      confirmation_request: Confirmations::PayloadBuilder.confirmation_request(request),
      delivery: Confirmations::PayloadBuilder.delivery(request: request, message: delivery_message, error: delivery_error)
    }
    payload[:status] = delivery_status(payload[:delivery], delivery_error)
    return partial_delivery_failure(payload) if delivery_error.present?

    JSON.pretty_generate(payload)
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

  def subject_from_state(state, subject_kind)
    return nil if subject_kind.blank?

    case subject_kind.to_s
    when 'conversation'
      current_conversation(state)
    when 'appointment'
      current_appointment(state)
    when 'deal'
      current_deal(state)
    when 'task'
      current_task(state)
    else
      raise ArgumentError, 'subject_kind must be one of: conversation, appointment, deal, task'
    end || raise(ArgumentError, "Current #{subject_kind} is not available")
  end

  def delivery_status(delivery, delivery_error)
    return 'partial' if delivery_error.present?
    return 'pending' if delivery&.dig(:status) == 'pending'

    'ok'
  end

  def partial_delivery_failure(payload)
    Captain::ToolResult.failure(
      error: 'Confirmation request was created, but the delivery outcome is unknown',
      data: payload,
      retryable: false,
      audit: {
        failure_reason: 'delivery_outcome_unknown',
        confirmation_request_id: payload.dig(:confirmation_request, :id),
        automatic_retry_blocked: true
      }
    )
  end
end
