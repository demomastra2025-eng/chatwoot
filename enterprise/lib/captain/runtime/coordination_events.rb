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

    # The editor events carry identifiers, the reply language and a reason only: never the reply or the customer's text.
    def council_edited(context:, part_ids:, language:, handoff:)
      publish_quietly('council.edited', context: context, parts: Array(part_ids), language: language.to_s,
                                        handoff: handoff.present?, reason: ('council_unresolved' if handoff))
    end

    def council_editor_fallback(context:, part_ids:, reason:)
      publish_quietly('council.editor_fallback', context: context, parts: Array(part_ids), reason: reason.to_s)
    end

    # Part events carry identifiers, states and counts only: never a text, a parameter or a tool result.
    def part_started(context:, part:, lane:, inline:)
      publish_part('council.part_started', context, part, lane: lane.to_s, inline: inline == true)
    end

    def part_finished(context:, part:, state:, status:, acted:, mutations_succeeded:, mutations_failed:, mutations_unknown:,
                      tools_called:, turns:, duration_ms:)
      publish_part('council.part_finished', context, part, state: state.to_s, status: status.to_s.presence, acted: acted == true,
                                                           mutations_succeeded: mutations_succeeded, mutations_failed: mutations_failed,
                                                           mutations_unknown: mutations_unknown, tools_called: tools_called, turns: turns,
                                                           duration_ms: duration_ms)
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

    def publish_part(name, context, part, **details)
      publish(name, context: context, part_id: part['id'], part_version: part['version'],
                    executor_agent_id: part['executor_agent_id'], **details)
    rescue StandardError => e
      # Monitoring must never change the outcome of a part.
      Rails.logger.warn("[CAPTAIN][CoordinationEvents] Failed to publish #{name}: #{e.class}")
    end
  end
end
