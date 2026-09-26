class Conversations::StatusTransitionService
  include DateRangeHelper

  def initialize(conversation:, params: {}, actor: nil, source: 'manual')
    @conversation = conversation
    @account = conversation.account
    @params = params.to_h.with_indifferent_access
    @actor = actor
    @source = source.to_s.presence || 'manual'
  end

  def perform
    return perform_captain_control_release_transition if explicit_captain_control_release?

    with_locked_conversation_preserving_changes { perform_transition }
  end

  private

  attr_reader :conversation, :account, :params, :actor, :source

  def perform_captain_control_release_transition
    with_locked_conversation_preserving_changes do
      control_owner = conversation.captain_control_owner
      if control_owner.equal?(conversation)
        perform_transition
      else
        conversation.with_captain_control_lock { perform_transition }
      end
    end
  end

  def with_locked_conversation_preserving_changes
    pending_attributes = conversation.attributes.slice(*conversation.changed_attribute_names_to_save.excluding('status'))
    conversation.restore_attributes

    conversation.with_lock do
      conversation.assign_attributes(pending_attributes)
      yield
    end
  end

  def perform_transition
    previous_status = conversation.status
    target_status = resolve_target_status(previous_status)
    status_changing = previous_status != target_status
    reason = reason_config.resolve_reason!(
      target_status,
      params[:status_reason],
      enforce_required: enforce_reason? && status_changing
    )

    prepare_captain_control_release!
    conversation.status = target_status
    assign_snoozed_until!
    changed = conversation.changed?
    conversation.save! if changed

    record_transition!(previous_status: previous_status, target_status: conversation.status, reason: reason) if changed && status_changing
    publish_captain_control_release!
    true
  end

  def explicit_captain_control_release?
    params[:status].to_s.in?(%w[pending resolved]) && actor.present? && source.in?(%w[api manual bulk_action communication_thread copilot]) &&
      conversation.respond_to?(:prepare_captain_ai_control!)
  end

  def prepare_captain_control_release!
    @captain_control_released = explicit_captain_control_release? && conversation.prepare_captain_ai_control!
  end

  def publish_captain_control_release!
    return unless @captain_control_released

    conversation.publish_captain_ai_control_activated!(source: source, actor: actor)
  end

  def resolve_target_status(previous_status)
    return params[:status].to_s if params[:status].present?

    previous_status == 'open' ? 'resolved' : 'open'
  end

  def assign_snoozed_until!
    return unless params.key?(:snoozed_until)

    conversation.snoozed_until = params[:snoozed_until].present? ? parse_date_time(params[:snoozed_until].to_s) : nil
  end

  def reason_config
    @reason_config ||= Conversations::StatusReasonConfig.new(account)
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

  def enforce_reason?
    %w[manual api bulk_action communication_thread captain copilot].include?(normalized_source)
  end

  def transition_metadata
    metadata = {}
    metadata[:snoozed_until] = conversation.snoozed_until.iso8601 if conversation.snoozed_until.present?
    metadata
  end
end
