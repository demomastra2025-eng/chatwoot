class Conversations::StatusTransitionService
  include DateRangeHelper

  # Lock the shared Captain control owner before its linked conversations.
  # Reopen, handoff and human actions must use the same order.
  def self.with_locked_conversations(thread)
    thread.with_lock do
      ::Conversation.where(id: thread.conversations.select(:id)).order(:id).lock('FOR UPDATE').load
      yield
    end
  end

  # rubocop:disable Metrics/ParameterLists
  def initialize(conversation:, params: {}, actor: nil, source: 'manual', audit: {}, aggregate: true)
    @conversation = conversation
    @account = conversation.account
    @params = params.to_h.with_indifferent_access
    @actor = actor
    @source = source.to_s.presence || 'manual'
    @reason_override = audit.to_h[:reason_override].to_s.squish.presence
    @metadata = audit.to_h.fetch(:metadata, {}).to_h.deep_stringify_keys
    @aggregate = aggregate
  end
  # rubocop:enable Metrics/ParameterLists

  def perform
    return perform_aggregate_transition if aggregate_transition?

    perform_single_transition
  end

  private

  attr_reader :conversation, :account, :params, :actor, :source, :reason_override, :metadata, :aggregate

  def perform_single_transition
    return perform_human_transition if human_action?

    apply_single_transition
  end

  def perform_human_transition
    conversation.with_captain_control_lock do
      apply_single_transition
      conversation.activate_captain_human_control!(source: source, actor: actor)
    end
    true
  end

  def apply_single_transition
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

  def human_action?
    return false unless actor.is_a?(User) && params[:status].to_s != 'pending'

    CaptainInbox.where(inbox_id: communication_thread ? communication_thread.conversations.select(:inbox_id) : [conversation.inbox_id]).exists?
  end

  def aggregate_transition?
    aggregate && communication_thread.present? && linked_conversations.many?
  end

  def perform_aggregate_transition
    target_status = resolve_target_status(conversation.status)
    aggregate_params = params.merge(status: target_status)

    self.class.with_locked_conversations(communication_thread) do
      linked_conversations.each do |linked_conversation|
        self.class.new(
          conversation: linked_conversation,
          params: aggregate_params,
          actor: actor,
          source: source,
          audit: { reason_override: reason_override, metadata: metadata },
          aggregate: false
        ).perform
      end
    end

    true
  end

  def communication_thread
    @communication_thread ||= conversation.communication_thread
  end

  def linked_conversations
    @linked_conversations ||= communication_thread.communication_thread_conversations
                                                  .includes(:conversation)
                                                  .map(&:conversation)
  end

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
