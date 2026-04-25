# frozen_string_literal: true

class Captain::Tools::Copilot::RequestConfirmationService < Captain::Tools::Copilot::BaseAccountTool
  def self.name
    'request_confirmation'
  end

  description 'Create a universal confirmation request for the current conversation, optionally bound to an appointment, deal, task, or standalone'
  param :title, type: :string, desc: 'Short confirmation title shown to the customer', required: true
  param :body, type: :string, desc: 'Confirmation message body shown to the customer', required: true
  param :subject_type, type: :string, desc: 'Optional subject type: Scheduling::Appointment, Crm::Deal, Crm::Task, or Conversation', required: false
  param :subject_id, type: :number, desc: 'Optional subject record ID; required when subject_type is provided', required: false
  param :expires_at, type: :string, desc: 'Optional expiration datetime in ISO 8601 format', required: false
  param :send_now, type: :boolean, desc: 'Whether to immediately send a channel-aware confirmation message. Defaults to true', required: false
  param :metadata, type: :object, desc: 'Optional structured metadata for this confirmation request', required: false
  param :idempotency_key, type: :string, desc: 'Optional account-scoped idempotency key to avoid duplicate pending requests', required: false

  # rubocop:disable Metrics/ParameterLists
  def execute(title:, body:, subject_type: nil, subject_id: nil, expires_at: nil, send_now: true, metadata: {}, idempotency_key: nil)
    request, delivery_message = confirmation_operations.request_confirmation(
      title: title,
      body: body,
      subject_type: subject_type,
      subject_id: subject_id,
      expires_at: expires_at,
      send_now: cast_boolean(send_now, default: true),
      metadata: metadata,
      idempotency_key: idempotency_key
    )

    formatted_payload(
      action: 'request_confirmation',
      confirmation_request: Confirmations::PayloadBuilder.confirmation_request(request),
      delivery: delivery_payload(delivery_message, request)
    )
  rescue StandardError => e
    tool_failure(e)
  end
  # rubocop:enable Metrics/ParameterLists

  private

  def confirmation_operations
    Captain::Tools::Operations::ConfirmationOperations.new(
      assistant: assistant,
      conversation: current_conversation,
      actor: @user
    )
  end

  def delivery_payload(delivery_message, request)
    return nil if delivery_message.blank?

    {
      message_id: delivery_message.id,
      content_type: delivery_message.content_type,
      delivery_strategy: request.delivery_strategy
    }
  end
end
