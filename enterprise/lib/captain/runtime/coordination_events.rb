# frozen_string_literal: true

class Captain::Runtime::CoordinationEvents
  class << self
    def council_started(context:, participant_ids:, part_ids: [])
      publish('council.started', context: context, participants: Array(participant_ids).map(&:to_i).uniq,
                                 parts: Array(part_ids))
    end

    def council_finished(context:, participant_ids:, outcome:, part_ids: [])
      publish('council.finished', context: context,
                                  participants: Array(participant_ids).map(&:to_i).uniq,
                                  parts: Array(part_ids), outcome: outcome.to_s)
    end

    # The composer events carry identifiers, the reply language and a reason only: never the reply or the customer's text.
    def council_composed(context:, part_ids:, language:, handoff:)
      publish_quietly('council.composed', context: context, parts: Array(part_ids), language: language.to_s,
                                          handoff: handoff.present?, reason: ('council_unresolved' if handoff))
    end

    def council_composer_fallback(context:, part_ids:, reason:)
      publish_quietly('council.composer_fallback', context: context, parts: Array(part_ids), reason: reason.to_s)
    end

    # Operation events carry identifiers and the outcome state only: no customer text and no parameters.
    def operation_started(context:, part:, tool_name:)
      publish_operation('operation.started', context, part, tool_name)
    end

    def operation_finished(context:, part:, tool_name:, state:)
      publish_operation('operation.finished', context, part, tool_name, state: state.to_s)
    end

    def publish(name, context:, **details)
      context = context.to_h.with_indifferent_access
      state = context[:state].to_h.with_indifferent_access
      conversation = state[:conversation].to_h.with_indifferent_access
      source = state[:source].to_s
      Llm::EventBus.publish(
        "captain.#{name}",
        {
          feature: 'assistant', runtime_mode: 'captain_runtime',
          account_id: state[:account_id], assistant_id: state[:assistant_id],
          conversation_id: conversation[:id], request_id: context[:agent_request_id] || Llm::EventBus.request_id,
          source: source.presence, run_source: %w[playground benchmark].include?(source) ? source : 'live'
        }.merge(details).compact
      )
    end

    private

    def publish_quietly(name, context:, **details)
      publish(name, context: context, **details)
    rescue StandardError => e
      # Monitoring must never change the reply.
      Rails.logger.warn("[CAPTAIN][CoordinationEvents] Failed to publish #{name}: #{e.class}")
    end

    def publish_operation(name, context, part, tool_name, **details)
      publish(name, context: context, part_id: part['id'], part_version: part['version'],
                    executor_agent_id: part['executor_agent_id'], tool_name: tool_name.to_s.presence, **details)
    rescue StandardError => e
      # Monitoring must never change the outcome of an operation.
      Rails.logger.warn("[CAPTAIN][CoordinationEvents] Failed to publish #{name}: #{e.class}")
    end
  end
end
