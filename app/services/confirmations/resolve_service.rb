# frozen_string_literal: true

class Confirmations::ResolveService
  DECISION_ALIASES = {
    'confirm' => 'confirmed',
    'confirmed' => 'confirmed',
    'decline' => 'declined',
    'declined' => 'declined',
    'cancel' => 'declined',
    'reschedule' => 'reschedule_requested',
    'reschedule_requested' => 'reschedule_requested'
  }.freeze

  # rubocop:disable Metrics/ParameterLists
  def initialize(account:, confirmation_request:, decision:, source:, actor: nil, message: nil, confidence: nil, metadata: {})
    @account = account
    @confirmation_request = confirmation_request
    @decision = DECISION_ALIASES[decision.to_s]
    @source = source.to_s
    @actor = actor
    @message = message
    @confidence = confidence
    @metadata = metadata || {}
  end
  # rubocop:enable Metrics/ParameterLists

  def perform
    validate_input!

    expired = false
    resolved_request = scoped_request.with_lock do
      if idempotent_resolution?
        scoped_request
      elsif !scoped_request.pending?
        raise ArgumentError, "confirmation request already #{scoped_request.status}"
      elsif scoped_request.past_due?
        expire_request!
        expired = true
        scoped_request
      else
        scoped_request.update!(resolution_attributes)
        scoped_request
      end
    end

    raise Confirmations::ExpiredRequestError, 'confirmation request expired' if expired

    enqueue_provider_command_resolution(resolved_request)
    resolved_request
  end

  private

  attr_reader :account, :confirmation_request, :decision, :source, :actor, :message, :confidence, :metadata

  def enqueue_provider_command_resolution(resolved_request)
    return if resolved_request.metadata.to_h['medelement_provider_command_id'].blank?

    Integrations::Medelement::ProviderCommandConfirmationJob.perform_later(resolved_request.id)
  end

  def validate_input!
    validate_decision!
    validate_source!
    validate_account_record!(actor, 'actor')
    validate_account_record!(message, 'message')
  end

  def validate_decision!
    return if ConfirmationRequest::STATUSES.include?(decision) && %w[pending expired].exclude?(decision)

    raise ArgumentError, 'decision must be one of: confirmed, declined, reschedule_requested'
  end

  def validate_source!
    return if ConfirmationRequest::RESOLUTION_SOURCES.include?(source)

    raise ArgumentError, "source must be one of: #{ConfirmationRequest::RESOLUTION_SOURCES.join(', ')}"
  end

  def scoped_request
    @scoped_request ||= ConfirmationRequest.where(account_id: account.id).find(confirmation_request.id)
  end

  def idempotent_resolution?
    !scoped_request.pending? && scoped_request.status == decision
  end

  def expire_request!
    scoped_request.update!(
      status: 'expired',
      resolved_at: Time.current,
      resolution_source: 'system',
      resolution_metadata: scoped_request.resolution_metadata.to_h.merge('reason' => 'expired')
    )
  end

  def resolution_attributes
    {
      status: decision,
      resolved_at: Time.current,
      resolved_by: actor,
      resolved_message: message,
      resolution_source: source,
      resolution_confidence: confidence,
      resolution_metadata: scoped_request.resolution_metadata.to_h.merge(metadata.to_h.as_json)
    }
  end

  def validate_account_record!(record, name)
    return if record.blank?
    return if record_belongs_to_account?(record)

    raise ArgumentError, "#{name} must belong to the current account"
  end

  def record_belongs_to_account?(record)
    return account.users.exists?(id: record.id) if record.is_a?(User)
    return record.account_id == account.id if record.respond_to?(:account_id)

    false
  end
end
