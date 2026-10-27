# frozen_string_literal: true

# What the router knows about one patient turn, as plain data that can cross threads. The live run builds it from the run
# context (.from_context, on the calling thread: database reads only, no model call); the evaluation harness builds it from an
# exported graph and a scenario (.from_fixture). Both feed the same Captain::Runtime::DecisionRouter.
#
# The state the decision model reads (#to_state) holds the agents by id, short label and competence card
# (Captain::Routing::CompetenceCard): every question of the call sees what every agent handles, so route_mode can tell one agent
# from several and an include_agent question can see that another agent names the topic explicitly. The card of an agent is also
# in the yes criterion of its include_agent question. Patient text is data for the model, never written to an event.
class Captain::Runtime::RoutingSnapshot
  MAX_RECENT_MESSAGES = 6
  TEXT_LIMIT = 500
  LATEST_LIMIT = 1500
  MAX_OPEN_QUESTIONS = 3
  MAX_VISITED = 5
  TRAIL_LIMIT = 3
  QUESTION_LIMIT = 300
  ATTACHMENT_MARKERS = { 'image_url' => '[image]', 'image' => '[image]', 'input_audio' => '[audio]', 'audio' => '[audio]' }.freeze

  Agent = Struct.new(:id, :label, :card, keyword_init: true)

  attr_reader :clinic, :patient_language, :current_agent_id, :agents, :recent_messages, :latest_message, :open_questions,
              :visited_agent_ids, :trail, :human_available, :source, :anchor_agent_id, :visit

  # agents: [Agent] (required); latest_message (required); clinic, patient_language, current_agent_id, recent_messages,
  # open_questions, visited_agent_ids, trail (the last routing decisions, oldest first: { 'kind', 'from', 'to' => [ids] }),
  # human_available, source. suggestion: the turn of a reply suggestion; anchor_agent_id: the anchor of its channel, which answers
  # a suggestion whose answers name no agent while no agent leads the dialog (see DecisionRouter::Questions). visit: the visit the
  # conversation has agreed (Captain::Runtime::AgreedVisit; none when absent), which a silence about a confirmation needs
  # (Captain::SilenceCheck).
  def initialize(**attributes)
    @agents = Array(attributes.fetch(:agents))
    @latest_message = attributes.fetch(:latest_message).to_s.strip.first(LATEST_LIMIT)
    @clinic = attributes[:clinic].to_s.squish.presence
    @patient_language = attributes[:patient_language].to_s.presence
    @human_available = attributes[:human_available] == true
    @source = attributes[:source].to_s.presence || 'live'
    @suggestion = attributes[:suggestion] == true
    @visit = attributes[:visit] || Captain::Runtime::AgreedVisit::NONE
    assign_conversation(attributes)
  end

  def agent_ids = @agents.map(&:id)

  def suggestion?
    @suggestion
  end

  # The dialog has messages before the turn (the patient's unanswered messages are the turn itself).
  def mid_dialog?
    @recent_messages.any?
  end

  def agent(id)
    @agents.find { |item| item.id == id.to_i }
  end

  # One candidate or none: nothing to choose, the router is not called.
  def solo?
    @agents.size < 2
  end

  def first_message?
    @current_agent_id.nil?
  end

  # The decision of the previous turn, for the state: none, agent, council or human, with the agents it chose.
  def last_turn
    entry = @trail.last
    return { kind: 'none', agent_ids: [] } unless entry

    { kind: entry['kind'].to_s.presence || 'none', agent_ids: Array(entry['to']).map(&:to_i) }
  end

  # The agent that passed the conversation to the current agent in the previous turn: a route straight back to it is a bounce.
  def bounce_source
    from = last_route_source
    from if from && @current_agent_id && from != @current_agent_id
  end

  def to_state
    {
      clinic: @clinic, patient_language: @patient_language, current_agent_id: @current_agent_id, last_turn: last_turn,
      visited_agent_ids: @visited_agent_ids, agents: @agents.map { |item| { id: item.id, label: item.label, handles: item.card.to_s } },
      recent_messages: @recent_messages, latest_message: @latest_message, open_questions: @open_questions
    }
  end

  # The same turn with another message to route and without some agents: a council part that answered "not mine" is decided
  # again on its own words, among the agents that remain.
  def narrowed(latest_message:, without: [])
    self.class.new(agents: @agents.reject { |item| Array(without).include?(item.id) }, latest_message: latest_message, clinic: @clinic,
                   patient_language: @patient_language, current_agent_id: @current_agent_id, recent_messages: @recent_messages,
                   open_questions: @open_questions, visited_agent_ids: @visited_agent_ids, trail: @trail,
                   human_available: @human_available, source: @source, suggestion: @suggestion, visit: @visit)
  end

  private

  # The agent the previous turn routed away from, when it routed to the current agent.
  def last_route_source
    entry = @trail.last.to_h
    return unless entry['kind'] == 'agent' && Array(entry['to']).map(&:to_i) == [@current_agent_id]

    entry['from'].presence&.to_i
  end

  def assign_conversation(attributes)
    @current_agent_id = candidate_id(attributes[:current_agent_id])
    @anchor_agent_id = candidate_id(attributes[:anchor_agent_id]) if @suggestion
    @recent_messages = Array(attributes[:recent_messages]).last(MAX_RECENT_MESSAGES)
    @open_questions = Array(attributes[:open_questions]).select { |question| agent_ids.include?(question[:agent_id]) }.last(MAX_OPEN_QUESTIONS)
    @visited_agent_ids = Array(attributes[:visited_agent_ids]).select { |id| agent_ids.include?(id) }.last(MAX_VISITED)
    @trail = Array(attributes[:trail]).last(TRAIL_LIMIT).map { |entry| entry.to_h.stringify_keys }
  end

  def candidate_id(value)
    id = value.presence&.to_i
    id if id && agent_ids.include?(id)
  end

  class << self
    # candidates: Captain::Routing::Candidate rows of the clinic (routable agents only).
    def agents_for(candidates)
      candidates = Array(candidates)
      candidates.map do |candidate|
        peers = candidates.reject { |peer| peer.id == candidate.id }
        Agent.new(id: candidate.id, label: Captain::Routing::CompetenceCard.label(candidate.name),
                  card: Captain::Routing::CompetenceCard.cached_text(candidate, peers: peers))
      end
    end

    # context: the prepared run context (see Captain::AgentRunContext#prepare). options: clinic, patient_language, human_available,
    # anchor_agent_id (a reply suggestion), visit.
    def from_context(context, candidates:, **)
      earlier, unanswered = split_history(context[:conversation_history])
      source = context.dig(:state, :source).to_s.presence || 'live'
      new(agents: agents_for(candidates), current_agent_id: context[:routing_current_agent_id], trail: context[:routing_trail],
          recent_messages: earlier.last(MAX_RECENT_MESSAGES).map { |message| state_message(message) },
          latest_message: latest_text(context[:captain_v2_current_input], unanswered), open_questions: open_questions(context[:parts]),
          visited_agent_ids: visited_ids(earlier), source: source, suggestion: source == 'reply_suggestion', **)
    end

    # [the public messages before the patient's unanswered ones, the patient's unanswered messages (they belong to this turn)]
    def split_history(history)
      public = Array(history).map { |raw| raw.to_h.with_indifferent_access }.select { |message| public_message?(message) }
      unanswered = public.reverse.take_while { |message| message[:role].to_s == 'user' }.reverse
      [public.first(public.size - unanswered.size), unanswered]
    end

    # scenario: one scenario of the router scenarios (current, history, message, language, open_questions, trail, human_available).
    # A reply suggestion scenario has sticky (the sticky agent of the dialog, the current agent of the turn; the saved session has
    # none) or suggestion: true, and anchor (the anchor of the channel).
    def from_fixture(candidates:, scenario:, clinic: nil)
      scenario = scenario.to_h.with_indifferent_access
      messages = Array(scenario[:history]).map { |entry| fixture_message(entry.to_h.with_indifferent_access) }
      new(agents: agents_for(candidates), clinic: clinic, patient_language: scenario[:language],
          current_agent_id: scenario[:current].presence || scenario[:sticky], recent_messages: messages,
          latest_message: scenario[:message].to_s, open_questions: Array(scenario[:open_questions]).map(&:symbolize_keys),
          visited_agent_ids: messages.filter_map { |message| message[:agent_id] }.reverse.uniq.reverse, trail: Array(scenario[:trail]),
          human_available: scenario.fetch(:human_available, true) != false, source: 'benchmark',
          suggestion: scenario.key?(:sticky) || scenario[:suggestion] == true, anchor_agent_id: scenario[:anchor],
          visit: Captain::Runtime::AgreedVisit.new(times: scenario[:visit_times], pending: scenario[:visit_pending]))
    end

    def public_message?(message)
      %w[user assistant].include?(message[:role].to_s) && message[:tool_calls].blank?
    end

    # The text of a stored message for the state: an assistant JSON reply is reduced to its response, an attachment to a marker.
    def text_of(content)
      case content
      when RubyLLM::Content then [content.text.to_s, *Array(content.attachments).map { |item| attachment_marker(item) }].compact_blank.join(' ')
      when Array then content.filter_map { |item| array_item_text(item) }.join(' ')
      when Hash then (content.with_indifferent_access[:response] || content.with_indifferent_access[:text]).to_s
      else json_response(content.to_s)
      end.squish
    end

    private

    def fixture_message(entry)
      { role: entry[:role].to_s == 'patient' ? 'patient' : 'clinic', agent_id: entry[:agent_id]&.to_i,
        text: entry[:text].to_s.squish.first(TEXT_LIMIT) }.compact
    end

    def state_message(message)
      role = message[:role].to_s == 'user' ? 'patient' : 'clinic'
      { role: role, agent_id: (agent_id_of(message) if role == 'clinic'), text: text_of(message[:content]).first(TEXT_LIMIT) }.compact
    end

    def latest_text(current_input, unanswered)
      texts = unanswered.map { |message| text_of(message[:content]) } + [text_of(current_input)]
      texts.compact_blank.join("\n").first(LATEST_LIMIT)
    end

    def visited_ids(messages)
      messages.filter_map { |message| agent_id_of(message) if message[:role].to_s == 'assistant' }.reverse.uniq.first(MAX_VISITED).reverse
    end

    def agent_id_of(message)
      Captain::HandoffNaming.agent_id_from_key(message[:agent_name])
    end

    # Questions an agent asked the patient that are still open, newest last: the answer belongs to the agent that asked.
    def open_questions(parts)
      stored = Array(parts)
      stored.select { |part| part['state'] == 'waiting_customer' && part['handed_to_staff'] != true }.last(MAX_OPEN_QUESTIONS).map do |part|
        question = Array(part['missing_fields']).join(' ').squish.presence || part['summary'].to_s.squish
        { number: Captain::Runtime::PartRegistry.number_of(stored, part['id']), agent_id: part['executor_agent_id'].to_i,
          question: question.first(QUESTION_LIMIT) }
      end
    end

    def array_item_text(item)
      item = item.to_h.with_indifferent_access if item.respond_to?(:to_h)
      return item.to_s unless item.is_a?(Hash)

      type = item[:type].to_s
      return item[:text].to_s if type == 'text'
      return document_marker(item.dig(:file, :filename) || item[:filename] || item[:title]) if %w[file document].include?(type)

      ATTACHMENT_MARKERS[type]
    end

    def attachment_marker(attachment)
      return '[image]' if attachment.respond_to?(:type) && attachment.type.to_s == 'image'

      document_marker(attachment.respond_to?(:filename) ? attachment.filename : nil)
    end

    def document_marker(name)
      name.to_s.strip.present? ? "[document: #{name.to_s.strip}]" : '[document]'
    end

    def json_response(text)
      stripped = text.strip
      return text unless stripped.start_with?('{')

      parsed = JSON.parse(stripped)
      parsed.is_a?(Hash) && parsed.key?('response') ? parsed['response'].to_s : text
    rescue JSON::ParserError
      text
    end
  end
end
