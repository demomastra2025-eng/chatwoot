# frozen_string_literal: true

class Captain::ShadowTraining::Snapshot
  MAX_HISTORY = 20
  MAX_TEXT = 4000
  MAX_FACTS = 60
  MODE = 'canonical_prompt_without_tools'
  LIMITATIONS = %w[no_tool_choice_evaluation no_live_actions no_availability_snapshot after_reply_facts time_variance
                   no_patient_record_context operator_is_not_ground_truth bounded_catalog bounded_history
                   human_reply_is_captured_version history_is_captured_version].freeze

  def initialize(inbound, assistants, current_assistant_id: nil)
    @inbound = inbound
    @assistants = assistants
    @current_assistant_id = current_assistant_id
  end

  def call
    captured_history = history
    {
      mode: MODE, limitations: LIMITATIONS, captured_at: Time.current.iso8601,
      inbound_at: @inbound.created_at.iso8601, history: captured_history, history_metadata: @history_metadata,
      current_assistant_id: @current_assistant_id,
      routing_agents: routing_agents.map(&:to_h), agent_contexts: agent_contexts, facts: facts
    }
  end

  private

  def account
    @inbound.account
  end

  def prompt_context
    # Explicit empty patient state prevents prompt field resolution from reading the patient's post-reply CRM state.
    Captain::Runtime::RunContext.new({ state: {
                                       source: 'shadow_training', mesh_routing: true, prompt_context: {},
                                       runtime_clock: { now_utc: @inbound.created_at.iso8601, timezone: account.reporting_timezone,
                                                        message_sent_at: @inbound.created_at.iso8601 }
                                     } })
  end

  def history
    rows = @inbound.conversation.messages.where(account_id: account.id, private: false, message_type: [:incoming, :outgoing])
                   .where('(created_at, id) <= (?, ?)', @inbound.created_at, @inbound.id)
                   .reorder(created_at: :desc, id: :desc).limit(MAX_HISTORY + 1).to_a
    unanswered = rows.take_while { |message| message.incoming? && public_sender?(message) }.size
    @history_metadata = { trailing_unanswered_count: unanswered, count_is_lower_bound: unanswered > MAX_HISTORY,
                          unanswered_overflow: unanswered > MAX_HISTORY }
    rows.first(MAX_HISTORY).reverse.filter_map { |message| history_row(message) }
  end

  def history_row(message)
    return if message.content.blank? || message.failed?
    return unless public_sender?(message)

    { role: message.incoming? ? 'user' : 'assistant', content: message.content.first(MAX_TEXT),
      message_id: message.id, sent_at: message.created_at.iso8601, truncated: message.content.length > MAX_TEXT }
  end

  def public_sender?(message)
    return message.sender_type == 'Contact' && message.sender_id == @inbound.sender_id if message.incoming?
    return account.users.exists?(id: message.sender_id) if message.sender_type == 'User'

    message.sender_type == 'Captain::Assistant' && message.sender&.account_id == account.id
  end

  def facts
    # No embeddings, network search, patient data, appointments, free-slot claims, or model tool calls.
    services + resources + prices
  end

  def services
    Scheduling::Service.where(account_id: account.id).active.order(:id).limit(MAX_FACTS).map do |row|
      fact('service', row, row.attributes.slice('name', 'category', 'direction', 'base_price', 'duration_min'))
    end
  end

  def resources
    Scheduling::Resource.where(account_id: account.id).available_for_scheduling.order(:id).limit(MAX_FACTS).map do |row|
      fact('resource', row, row.attributes.slice('name', 'specialty'))
    end
  end

  def prices
    Scheduling::ServicePrice.where(account_id: account.id, service_id: Scheduling::Service.where(account_id: account.id).active.select(:id),
                                   resource_id: Scheduling::Resource.where(account_id: account.id).available_for_scheduling.select(:id))
                            .active.order(:id).limit(MAX_FACTS).map do |row|
      fact('price', row, row.attributes.slice('service_id', 'resource_id', 'price'))
    end
  end

  def faq(assistant)
    Captain::AssistantResponse.where(account_id: account.id).approved.visible_to_assistant(assistant.id).order(:id).limit(MAX_FACTS).map do |row|
      fact('faq', row, { question: row.question, answer: row.answer.first(MAX_TEXT) })
    end
  end

  def routing_agents
    candidates = @assistants.map { |assistant| Captain::Routing::Candidate.from_assistant(assistant) }
    Captain::Runtime::RoutingSnapshot.agents_for(candidates)
  end

  def agent_contexts
    @assistants.to_h do |assistant|
      [assistant.id.to_s, { system_prompt: assistant.agent_instructions(prompt_context), faq: faq(assistant) }]
    end
  end

  def fact(kind, row, data)
    { ref: "#{kind}:#{row.id}", updated_at: row.updated_at.iso8601, data: data }
  end
end
