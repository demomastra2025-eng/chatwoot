# frozen_string_literal: true

# The agent that leads a dialog for «Предложить ответ». A reply suggestion never writes the conversation's session, and in a clinic
# where the AI only suggests, operators send the replies: the saved session has no current agent and the messages carry no agent.
# Without one the router has no current agent, so a short answer mid-dialog («Да, на 14:00», an IIN, «Спасибо») cannot stay with
# the agent that is booking it. This is that agent (Captain::AgentRunContext reads it as the current agent of a suggestion run; the
# router decides the rest, and a route to another agent makes that agent the sticky one).
#
# It is kept in Redis per conversation and per person thread, in two kinds, each with the time it was written; the newest value of
# all of them is the sticky agent, so the person's latest dialog wins over an older one in another channel («Контакт = Диалог»):
#   provisional  the agent of a finished suggestion (GenerateJob), for as long as its request lives (30 minutes). A rejected
#                suggestion («Отклонить»), a closed notice of it and a new suggestion of the same manager that supersedes it
#                («Предложить ответ» / «Повторить» again, StartService) withdraw it, and the value before it applies again.
#   confirmed    the agent of a suggestion the manager inserted or sent (FeedbackService), for 24 hours.
# A suggestion that the anchor answered only because no agent leads the dialog (the router's default_to anchor) makes nobody
# sticky. Resolving the conversation clears it (CaptainListener). A message the manager writes by hand (an outgoing public message
# of a user that did not come from a used suggestion, CaptainListener#message_created) leaves a mark in the conversation and in the
# person's thread (ManualReply): every value written before that message no longer leads the dialog, whichever conversation of the
# person it was written in (the manager took the dialog elsewhere, so a short reply to it must not go back to the old agent).
module Captain::ReplySuggestion::StickyAgent
  PREFIX = "#{Captain::ReplySuggestion::RequestStore::PREFIX}:sticky_agent".freeze
  CONFIRMED_TTL_SECONDS = 24.hours.to_i
  PROVISIONAL_TTL_SECONDS = Captain::ReplySuggestion::TTL_SECONDS
  KINDS = %w[confirmed provisional].freeze
  # Outcomes whose agent leads the dialog afterwards. A staff request of the router, a safety stop and a custom rule name no agent.
  AGENT_OUTCOMES = %w[draft no_reply].freeze

  class << self
    # The sticky agent id of the conversation and the person's thread (the newest value); nil when there is none.
    def read(conversation)
      return if conversation.blank?

      keys = keys_for(conversation)
      raws = Redis::Alfred.mget(keys + ManualReply.keys(conversation))
      newest_agent_id(raws.first(keys.size), after: ManualReply.latest(raws.drop(keys.size)))
    rescue StandardError => e
      Rails.logger.warn("[CAPTAIN][ReplySuggestion] sticky agent unreadable error_class=#{e.class.name}")
      nil
    end

    # The agent of a finished suggestion, until the manager uses or rejects it.
    def remember_provisional!(conversation, agent_id, request_id:)
      write(conversation, 'provisional', agent_id, request_id, PROVISIONAL_TTL_SECONDS)
    end

    # The manager inserted or sent the suggestion of this agent.
    def confirm!(conversation, agent_id, request_id:)
      write(conversation, 'confirmed', agent_id, request_id, CONFIRMED_TTL_SECONDS)
    end

    # The manager rejected the suggestion of this request: its provisional agent goes, and the value before it applies again.
    def withdraw!(conversation, request_id:)
      return if conversation.blank? || request_id.blank?

      keys_for(conversation, kinds: %w[provisional]).each { |key| withdraw_key(key) { |entry| entry['request_id'] == request_id.to_s } }
    rescue StandardError => e
      Rails.logger.warn("[CAPTAIN][ReplySuggestion] sticky agent not withdrawn error_class=#{e.class.name}")
    end

    # A new suggestion of this manager (keep_request_id) supersedes the earlier ones nobody used: their provisional agents go, so the
    # dialog is led again by the confirmed agent (or by nobody). A provisional agent of another manager's live request stays.
    def withdraw_superseded!(conversation, user_id:, keep_request_id:)
      return if conversation.blank?

      superseded = ->(request_id) { superseded?(request_id, user_id, keep_request_id) }
      keys_for(conversation, kinds: %w[provisional]).each { |key| withdraw_key(key) { |entry| superseded.call(entry['request_id'].to_s) } }
    rescue StandardError => e
      Rails.logger.warn("[CAPTAIN][ReplySuggestion] superseded sticky agent not withdrawn error_class=#{e.class.name}")
    end

    # The conversation was resolved: its dialog has nobody leading it any more.
    def clear!(conversation)
      return if conversation.blank?

      keys_for(conversation, kinds: KINDS + [ManualReply::KIND]).each { |key| Redis::Alfred.delete(key) }
    rescue StandardError => e
      Rails.logger.warn("[CAPTAIN][ReplySuggestion] sticky agent not cleared error_class=#{e.class.name}")
    end

    # The agent an outcome makes sticky: the agent of a draft or of a "no reply needed" (for a council, the agent it leaves the dialog
    # with: lead_agent_id), and of a staff request that the agent itself made (reason_source agent); nil for everything else.
    def agent_id_of(outcome)
      outcome = outcome.to_h.with_indifferent_access
      kind = outcome[:outcome].to_s
      return unless AGENT_OUTCOMES.include?(kind) || (kind == 'human_needed' && outcome[:reason_source].to_s == 'agent')

      agent_id_of_result(outcome)
    end

    # The agent of a stored draft (see FeedbackService), or of an outcome; nil when the anchor answered only because no agent led
    # the dialog (routing_default_to of an outcome, the routing of a stored draft).
    def agent_id_of_result(result)
      result = result.to_h.with_indifferent_access
      return if anchor_default?(result)

      (result[:lead_agent_id].presence || result[:agent].to_h.with_indifferent_access[:id]).presence&.to_i
    end

    def keys_for(conversation, kinds: KINDS)
      scopes = ["conversation:#{conversation.id}"]
      thread_id = thread_id_for(conversation)
      scopes << "thread:#{thread_id}" if thread_id
      scopes.product(kinds).map { |scope, kind| "#{PREFIX}:#{conversation.account_id}:#{scope}:#{kind}" }
    end

    private

    def write(conversation, kind, agent_id, request_id, ttl)
      id = agent_id.to_i
      return if conversation.blank? || !id.positive?

      value = JSON.generate({ 'agent_id' => id, 'at' => Time.current.to_f, 'request_id' => request_id.to_s.presence }.compact)
      keys_for(conversation, kinds: [kind]).each { |key| Redis::Alfred.set(key, value, ex: ttl) }
      id
    rescue StandardError => e
      Rails.logger.warn("[CAPTAIN][ReplySuggestion] sticky agent not stored error_class=#{e.class.name}")
      nil
    end

    def parse(raw)
      return if raw.blank?

      entry = JSON.parse(raw)
      entry if entry.is_a?(Hash) && entry['agent_id'].to_i.positive?
    rescue JSON::ParserError
      nil
    end

    # The agent of the newest value written after the manager's last manual reply (after: its time).
    def newest_agent_id(raws, after:)
      entries = raws.filter_map { |raw| parse(raw) }.select { |entry| entry['at'].to_f > after }
      entries.max_by { |entry| entry['at'].to_f }&.dig('agent_id')
    end

    # Another request than the new one, that is gone (expired) or that this manager made.
    def superseded?(request_id, user_id, keep_request_id)
      return false if request_id.blank? || request_id == keep_request_id.to_s

      Captain::ReplySuggestion::RequestStore.fetch_raw(request_id).then { |record| record.nil? || record['user_id'].to_i == user_id.to_i }
    end

    # Deletes the value of the key when the block says so (and nobody changed it meanwhile).
    def withdraw_key(key)
      raw = Redis::Alfred.get(key)
      entry = parse(raw)
      Redis::Alfred.delete_if_value(key, raw) if entry && yield(entry)
    end

    def anchor_default?(result)
      result[:routing_default_to].to_s == 'anchor' || result.dig(:suggestion_meta, :routing, :default_to).to_s == 'anchor'
    end

    def thread_id_for(conversation)
      conversation.communication_thread&.id
    rescue StandardError
      nil
    end
  end
end
