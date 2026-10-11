# frozen_string_literal: true

class Captain::Runtime::CoordinationEvents
  class << self
    def council_started(context:, participant_ids:)
      publish('council.started', context: context, participants: Array(participant_ids).map(&:to_i).uniq)
    end

    def council_finished(context:, participant_ids:, outcome:)
      publish('council.finished', context: context,
                                  participants: Array(participant_ids).map(&:to_i).uniq, outcome: outcome.to_s)
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
  end
end
