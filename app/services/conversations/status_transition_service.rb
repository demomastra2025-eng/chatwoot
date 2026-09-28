class Conversations::StatusTransitionService
  include DateRangeHelper

  # rubocop:disable Metrics/ParameterLists
  def initialize(conversation:, params: {}, actor: nil, source: 'manual', audit: {}, aggregate: true,
                 source_record: nil, source_event_id: nil, occurred_at: nil)
    @conversation = conversation
    @account = conversation.account
    @params = params.to_h.with_indifferent_access
    @actor = actor
    @source = source.to_s.presence || 'manual'
    @reason_override = audit.to_h[:reason_override].to_s.squish.presence
    @metadata = audit.to_h.fetch(:metadata, {}).to_h.deep_stringify_keys
    @aggregate = aggregate
    @source_record = source_record || conversation
    @source_event_id = source_event_id.presence || SecureRandom.uuid
    @occurred_at = occurred_at || Time.current
  end
  # rubocop:enable Metrics/ParameterLists

  def perform
    return perform_aggregate_transition if aggregate_transition?
    return perform_single_transition if communication_thread.present?

    self.class.with_locked_contact_threads_for_unlinked(conversation) { perform_single_transition }
  end

  def self.with_locked_contact_threads_for_unlinked(conversation)
    Conversation.transaction do
      Conversations::CommunicationThreadResolver.lock_contact_thread!(conversation.account_id, conversation.contact_id)
      CommunicationThread.where(account_id: conversation.account_id, contact_id: conversation.contact_id).order(:id).lock.load
      yield
    end
  end

  def self.with_locked_conversations(thread)
    Conversation.transaction do
      Conversations::CommunicationThreadResolver.lock_contact_thread!(thread.account_id, thread.contact_id)
      thread.lock!
      ids = thread.communication_thread_conversations.order(:conversation_id).pluck(:conversation_id)
      Conversation.where(account_id: thread.account_id, id: ids).order(:id).lock.load
      yield
    end
  end

  def self.with_locked_conversations_for(conversation, &)
    thread = conversation.communication_thread
    return with_locked_contact_threads_for_unlinked(conversation) { conversation.with_lock(&) } unless thread

    with_locked_conversations(thread) do
      conversation.lock! # Preserve with_lock's reload semantics after acquiring the ordered group.
      yield
    end
  end

  private

  attr_reader :conversation, :account, :params, :actor, :source, :reason_override, :metadata, :aggregate,
              :source_record, :source_event_id, :occurred_at

  def perform_single_transition
    return perform_captain_control_release_transition if explicit_captain_control_release?

    perform_transition
  end

  def perform_captain_control_release_transition
    pending_attributes = conversation.attributes.slice(*conversation.changed_attribute_names_to_save.excluding('status'))
    conversation.restore_attributes

    Conversation.transaction do
      Conversations::CommunicationThreadResolver.lock_contact_thread!(conversation.account_id, conversation.contact_id)
      conversation.with_captain_control_lock do
        conversation.with_lock do
          conversation.assign_attributes(pending_attributes)
          perform_transition
        end
      end
    end
  end

  def perform_transition
    previous_status = conversation.status
    target_status = resolve_target_status(previous_status)
    status_changing = previous_status != target_status
    reason = reason_override

    prepare_captain_control_release!
    conversation.status = target_status
    assign_thread_transition_context!
    assign_snoozed_until!
    changed = conversation.changed?
    conversation.save! if changed

    record_transition!(previous_status: previous_status, target_status: conversation.status, reason: reason) if changed && status_changing
    publish_captain_control_release!
    true
  ensure
    conversation.clear_communication_thread_event_context! unless changed
  end

  def aggregate_transition?
    aggregate && communication_thread.present? && linked_conversations.many?
  end

  def explicit_captain_control_release?
    params[:status].to_s.in?(%w[pending resolved]) && actor.present? && source.in?(%w[api manual bulk_action communication_thread copilot]) &&
      conversation.respond_to?(:prepare_captain_ai_control!)
  end

  def perform_aggregate_transition
    self.class.with_locked_conversations(communication_thread) do
      @linked_conversations = nil # Re-read status after acquiring every row lock.
      target_status = resolve_target_status(linked_conversations.find { |linked| linked.id == conversation.id }&.status || conversation.status)
      aggregate_params = params.merge(status: target_status)
      linked_conversations.each { |linked_conversation| transition_linked_conversation!(linked_conversation, aggregate_params) }
      refresh_aggregate_thread!
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

  def prepare_captain_control_release!
    @captain_control_released = explicit_captain_control_release? && conversation.prepare_captain_ai_control!
  end

  def publish_captain_control_release!
    return unless @captain_control_released

    conversation.publish_captain_ai_control_activated!(source: source, actor: actor)
  end

  def refresh_aggregate_thread!
    Conversations::CommunicationThreadResolver.new(
      conversation: linked_conversations.first,
      actor: actor,
      source: source,
      source_record: communication_thread,
      source_event_id: source_event_id,
      occurred_at: occurred_at
    ).perform
  end

  def transition_linked_conversation!(linked_conversation, aggregate_params)
    linked_conversation.skip_communication_thread_refresh = true
    self.class.new(
      conversation: linked_conversation,
      params: aggregate_params,
      actor: actor,
      source: source,
      audit: { reason_override: reason_override, metadata: metadata },
      aggregate: false,
      source_record: communication_thread,
      source_event_id: source_event_id,
      occurred_at: occurred_at
    ).perform
  end

  def resolve_target_status(previous_status)
    return params[:status].to_s if params[:status].present?

    previous_status == 'open' ? 'resolved' : 'open'
  end

  def assign_snoozed_until!
    return unless params.key?(:snoozed_until)

    conversation.snoozed_until = params[:snoozed_until].present? ? parse_date_time(params[:snoozed_until].to_s) : nil
  end

  def assign_thread_transition_context!
    # No Thread fact exists for an unlinked Conversation; keep its activity
    # payload unchanged rather than publishing an orphan event identifier.
    return unless conversation.communication_thread

    conversation.communication_thread_event_id = source_event_id
    conversation.communication_thread_event_actor = actor
    conversation.communication_thread_event_source = source
    conversation.communication_thread_event_source_record = source_record
    conversation.communication_thread_event_occurred_at = occurred_at
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
