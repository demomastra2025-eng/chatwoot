# frozen_string_literal: true

# Writes what the router decided into the durable session of the conversation: the agent that now holds the conversation (with
# the routing revision the response fence carries, so a reply of a run that lost the conversation is dropped) and the short trail
# of the last decisions the next turn reads (for the bounce guard and the state of the router). A reply suggestion has an
# ephemeral session: nothing reaches the conversation.
class Captain::Runtime::RoutingState
  def initialize(context)
    @context = context
  end

  # actor_id: the agent that holds the conversation after this turn (nil keeps the current one). trail: { kind:, from:, to: }.
  def persist!(actor_id:, trail: nil)
    session = @context[:agent_session]
    return unless session

    entry = trail_entry(trail)
    revision = session.update_routing(actor_id: actor_id, trail: entry)
    state = @context[:state] ||= {}
    state[:agent_routing_revision] = revision
    fence = state[:captain_response_fence]
    return revision if fence.blank? || actor_id.nil?

    fence[:entry_assistant_id] = state[:entry_assistant_id]
    fence[:routing_revision] = revision
    revision
  end

  private

  def trail_entry(trail)
    return if trail.blank?

    fence = @context.dig(:state, :captain_response_fence).to_h.with_indifferent_access
    { 'message_id' => fence[:last_message_id], 'kind' => trail[:kind].to_s, 'from' => trail[:from],
      'to' => Array(trail[:to]).map(&:to_i) }.compact
  end
end
