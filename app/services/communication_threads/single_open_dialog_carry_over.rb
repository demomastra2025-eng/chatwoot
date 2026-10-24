# frozen_string_literal: true

# What the conversation that stays open takes over from the ones that were just resolved, so that nothing the person or
# the team relied on disappears with them:
# - the labels (the label list of the kept conversation becomes the union),
# - the "waiting for a callback" state of a missed call, which stays on the resolved conversation too: the existing
#   clearing (Telephony::MissedCallCallbackTracker.clear_for_contact!) finds every flagged conversation of the contact, so
#   the call message of the resolved voice conversation is cleared with the others once the callback happens,
# - the assignee and the team of the thread, when the kept conversation has none (an agent sees only what is assigned to
#   them or to nobody).
# The kept conversation is saved without events, activity messages and thread refresh; the caller refreshes the thread once.
class CommunicationThreads::SingleOpenDialogCarryOver
  CALLBACK_ADDITIONAL_KEYS = %w[last_missed_call_ref last_missed_call_at].freeze

  # Returns true when something on the kept conversation changed.
  def self.perform(plan)
    new(plan).perform
  end

  def initialize(plan)
    @plan = plan
    @kept = plan.kept
    @closed = plan.closed
  end

  def perform
    @kept.skip_runtime_events = true
    @kept.skip_activity_messages = true
    @kept.skip_communication_thread_refresh = true

    labels_changed = merge_labels
    callback_changed = carry_callback_state
    @kept.save! if labels_changed || callback_changed || @kept.changed?
    routing_changed = fill_routing
    labels_changed || callback_changed || routing_changed
  end

  private

  def merge_labels
    current = @kept.label_list.to_a
    merged = (current + @closed.flat_map { |conversation| conversation.label_list.to_a }).uniq
    return false if merged.sort == current.sort

    @kept.label_list = merged
    true
  end

  def carry_callback_state
    source = callback_source
    return false if source.blank? || source.equal?(@kept)

    @kept.custom_attributes = @kept.custom_attributes.to_h.merge('waiting_for_callback' => true)
    @kept.additional_attributes = @kept.additional_attributes.to_h
                                       .merge('waiting_for_callback' => true)
                                       .merge(source.additional_attributes.to_h.slice(*CALLBACK_ADDITIONAL_KEYS))
    true
  end

  # The conversation holding the latest missed call; the kept conversation wins a tie.
  def callback_source
    flagged = ([@kept] + @closed).select { |conversation| Telephony::MissedCallCallbackTracker.waiting_for_callback?(conversation) }
    flagged.max_by { |conversation| [missed_call_time(conversation), conversation.equal?(@kept) ? 1 : 0] }
  end

  def missed_call_time(conversation)
    Time.zone.parse(conversation.additional_attributes.to_h['last_missed_call_at'].to_s).to_f
  rescue ArgumentError
    0.0
  end

  def fill_routing
    thread = @plan.thread
    attributes = {}
    attributes[:assignee_id] = thread.assignee_id if @kept.assignee_id.blank? && assignable?(thread.assignee_id)
    attributes[:team_id] = thread.team_id if @kept.team_id.blank? && thread.team_id.present?
    return false if attributes.empty?

    @kept.update_columns(attributes.merge(updated_at: Time.current)) # rubocop:disable Rails/SkipsModelValidations
    true
  end

  def assignable?(user_id)
    user_id.present? && @kept.inbox.assignable_agents.any? { |agent| agent.id == user_id }
  end
end
