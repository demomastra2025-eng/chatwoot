class Conversations::StatusTransitionService
  include DateRangeHelper

  def initialize(conversation:, params: {}, actor: nil, source: 'manual', audit: {})
    @conversation = conversation
    @account = conversation.account
    @params = params.to_h.with_indifferent_access
    @actor = actor
    @source = source.to_s.presence || 'manual'
    @reason_override = audit.to_h[:reason_override].to_s.squish.presence
    @metadata = audit.to_h.fetch(:metadata, {}).to_h.deep_stringify_keys
  end

  def perform
    previous_status = conversation.status
    target_status = resolve_target_status(previous_status)
    status_changing = previous_status != target_status
    reason = reason_override

    conversation.status = target_status
    assign_snoozed_until!
    changed = conversation.changed?
    conversation.save! if changed

    record_transition!(previous_status: previous_status, target_status: conversation.status, reason: reason) if changed && status_changing
    true
  end

  private

  attr_reader :conversation, :account, :params, :actor, :source, :reason_override, :metadata


  def resolve_target_status(previous_status)
    return params[:status].to_s if params[:status].present?

    previous_status == 'open' ? 'resolved' : 'open'
  end

  def assign_snoozed_until!
    return unless params.key?(:snoozed_until)

    conversation.snoozed_until = params[:snoozed_until].present? ? parse_date_time(params[:snoozed_until].to_s) : nil
  end


  def record_transition!(previous_status:, target_status:, reason:)
    ConversationStatusTransition.create!(
      account: account,
      conversation: conversation,
      actor: actor,
      from_status: previous_status,
      to_status: target_status,
      reason: reason,
      source: normalized_source,
      metadata: transition_metadata
    )
  end

  def normalized_source
    return source if ConversationStatusTransition::VALID_SOURCES.include?(source)

    'manual'
  end


  def transition_metadata
    result = metadata.deep_dup
    result[:snoozed_until] = conversation.snoozed_until.iso8601 if conversation.snoozed_until.present?
    result
  end
end
