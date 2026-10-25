# frozen_string_literal: true

# The agent that leads a dialog for «Предложить ответ». A reply suggestion never writes the conversation's session, and in a clinic
# where the AI only suggests, operators send the replies: the saved session has no current agent and the messages carry no agent.
# Without one the router has no current agent, so a short answer mid-dialog («Да, на 14:00», an IIN, «Спасибо») cannot stay with
# the agent that is booking it. This is that agent: the agent of the last finished, inserted or sent suggestion, kept in Redis for
# 24 hours per conversation and per person thread (Captain::AgentRunContext reads it as the current agent of a suggestion run;
# the router decides the rest, and a route to another agent makes that agent the sticky one).
module Captain::ReplySuggestion::StickyAgent
  PREFIX = "#{Captain::ReplySuggestion::RequestStore::PREFIX}:sticky_agent".freeze
  TTL_SECONDS = 24.hours.to_i
  # Outcomes whose agent leads the dialog afterwards. A staff request of the router, a safety stop and a custom rule name no agent.
  AGENT_OUTCOMES = %w[draft no_reply].freeze

  class << self
    # The sticky agent id of the conversation, else of the person's thread; nil when there is none.
    def read(conversation)
      return if conversation.blank?

      keys_for(conversation).each do |key|
        id = Redis::Alfred.get(key).to_i
        return id if id.positive?
      end
      nil
    rescue StandardError => e
      Rails.logger.warn("[CAPTAIN][ReplySuggestion] sticky agent unreadable error_class=#{e.class.name}")
      nil
    end

    def remember!(conversation, agent_id)
      id = agent_id.to_i
      return if conversation.blank? || !id.positive?

      keys_for(conversation).each { |key| Redis::Alfred.set(key, id, ex: TTL_SECONDS) }
      id
    rescue StandardError => e
      Rails.logger.warn("[CAPTAIN][ReplySuggestion] sticky agent not stored error_class=#{e.class.name}")
      nil
    end

    # The agent an outcome makes sticky: the agent of a draft or of a "no reply needed", and of a staff request that the agent itself
    # made (reason_source agent); nil for everything else.
    def agent_id_of(outcome)
      outcome = outcome.to_h.with_indifferent_access
      kind = outcome[:outcome].to_s
      return unless AGENT_OUTCOMES.include?(kind) || (kind == 'human_needed' && outcome[:reason_source].to_s == 'agent')

      outcome[:agent].to_h.with_indifferent_access[:id].presence&.to_i
    end

    def keys_for(conversation)
      keys = ["#{PREFIX}:#{conversation.account_id}:conversation:#{conversation.id}"]
      thread_id = thread_id_for(conversation)
      keys << "#{PREFIX}:#{conversation.account_id}:thread:#{thread_id}" if thread_id
      keys
    end

    private

    def thread_id_for(conversation)
      conversation.communication_thread&.id
    rescue StandardError
      nil
    end
  end
end
