# frozen_string_literal: true

# The monitoring events of the router. Identifiers, keys, models, confidences, latencies and codes only: never patient text,
# a prompt, a provider body or a key.
#   captain.agent.routed          one per routed turn (and per re-decided council part)
#   captain.agent.routing_failed  the router could not decide: the turn went to staff through the technical-failure path
#   captain.agent.transfer        the agent that holds the conversation changed (the transfers report reads it)
module Captain::Runtime::RoutingEvents
  module_function

  def routed(context:, decision:, from_agent_id:, routing_request_id:)
    publish('agent.routed', context, decision.to_event_payload.merge(from_agent_id: from_agent_id, routing_request_id: routing_request_id))
  end

  def failed(context:, error:, routing_request_id:, from_agent_id: nil)
    publish('agent.routing_failed', context, reason: error.reason, detail: error.detail, models_tried: error.models_tried,
                                             from_agent_id: from_agent_id, routing_request_id: routing_request_id)
  end

  def transfer(context:, from_agent_id:, to_agent_id:)
    return if from_agent_id.present? && from_agent_id.to_i == to_agent_id.to_i

    publish('agent.transfer', context, from_agent_id: from_agent_id, to_agent_id: to_agent_id)
  end

  def publish(name, context, details)
    Captain::Runtime::CoordinationEvents.publish(name, context: context, **details.compact)
  rescue StandardError => e
    # Monitoring must never change the turn.
    Rails.logger.warn("[CAPTAIN][RoutingEvents] Failed to publish #{name}: #{e.class}")
  end
end
