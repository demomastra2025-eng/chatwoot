# frozen_string_literal: true

class Captain::Tools::Operations::ConfirmationOperations < Captain::Tools::Operations::BaseOperation
  SUBJECT_TYPES_BY_KIND = {
    'conversation' => 'Conversation',
    'appointment' => 'Scheduling::Appointment',
    'deal' => 'Crm::Deal',
    'task' => 'Crm::Task'
  }.freeze

  # rubocop:disable Metrics/ParameterLists
  def request_confirmation(
    title:, body:, subject: nil, subject_kind: nil, subject_type: nil,
    subject_id: nil, expires_at: nil, send_now: true, metadata: {}, idempotency_key: nil
  )
    resolved_subject = subject || resolve_subject(subject_kind: subject_kind, subject_type: subject_type, subject_id: subject_id)
    request = Confirmations::CreateService.new(
      account: account,
      conversation: conversation,
      subject: resolved_subject,
      title: title,
      body: body,
      expires_at: parse_datetime(expires_at),
      requester: actor,
      metadata: parsed_hash(metadata, field_name: 'metadata'),
      idempotency_key: idempotency_key
    ).perform

    delivery_message, delivery_error = deliver_confirmation(request, send_now)
    [request, delivery_message, delivery_error]
  end
  # rubocop:enable Metrics/ParameterLists

  def resolve_confirmation(confirmation_request_id:, decision:, source:, confidence: nil, metadata: {})
    request = ConfirmationRequest.where(account_id: account.id).find(confirmation_request_id)
    Confirmations::ResolveService.new(
      account: account,
      confirmation_request: request,
      decision: decision,
      source: source,
      actor: actor,
      confidence: confidence,
      metadata: parsed_hash(metadata, field_name: 'metadata')
    ).perform
  end

  private

  def deliver_confirmation(request, send_now)
    return [nil, nil] unless send_now

    [Confirmations::DeliveryService.new(confirmation_request: request, sender: actor).perform, nil]
  rescue StandardError => e
    request.update!(
      metadata: request.metadata.to_h.merge(
        'delivery_status' => 'unknown',
        'delivery_outcome_known' => false,
        'delivery_error_code' => e.class.name,
        'delivery_outcome_unknown_at' => Time.current.iso8601,
        'delivery_recovery_confirmation_request_id' => request.id
      )
    )
    [nil, e]
  end

  def resolve_subject(subject_kind:, subject_type:, subject_id:)
    return resolve_subject_by_kind(subject_kind) if subject_kind.present?
    return nil if subject_type.blank? && subject_id.blank?

    normalized_type = subject_type.to_s
    validate_subject_type!(normalized_type)
    raise ArgumentError, 'subject_id is required when subject_type is provided' if subject_id.blank?

    normalized_type.constantize.where(account_id: account.id).find(subject_id)
  end

  def validate_subject_type!(normalized_type)
    return if ConfirmationRequest::SUPPORTED_SUBJECT_TYPES.include?(normalized_type)

    raise ArgumentError, "subject_type must be one of: #{ConfirmationRequest::SUPPORTED_SUBJECT_TYPES.join(', ')}"
  end

  def resolve_subject_by_kind(subject_kind)
    normalized_kind = subject_kind.to_s
    raise ArgumentError, "subject_kind must be one of: #{SUBJECT_TYPES_BY_KIND.keys.join(', ')}" unless SUBJECT_TYPES_BY_KIND.key?(normalized_kind)

    case normalized_kind
    when 'conversation'
      conversation
    when 'appointment'
      current_appointment
    when 'deal'
      current_deal
    when 'task'
      current_task
    end || raise(ArgumentError, "Current #{normalized_kind} is not available")
  end

  def parse_datetime(value)
    return nil if value.blank?

    parsed = Time.zone.parse(value.to_s)
    raise ArgumentError, 'expires_at must be a valid datetime' if parsed.blank?

    parsed
  end
end
