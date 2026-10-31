# frozen_string_literal: true

# Compact facts from one Captain run. Tool arguments and result bodies never enter classifier input.
class Captain::OutcomeFacts
  LIMIT = 20
  NOTE_LIMIT = 1000
  INSTRUCTION_LIMIT = 12_000
  AVAILABILITY_TOOLS = %w[
    search_available_slots search_booking_options get_scheduling_resource_availability
  ].freeze
  FAILURE_KINDS = {
    'time_taken' => 'slot_taken', 'slot_taken' => 'slot_taken', 'validation_error' => 'validation_error',
    'invalid_tool_arguments' => 'validation_error', 'service_resource_mismatch' => 'validation_error',
    'provider_unavailable' => 'calendar_unavailable', 'schedule_not_confirmed' => 'calendar_unavailable',
    'medelement_availability_unverified' => 'calendar_unavailable',
    'permission_denied' => 'permission', 'forbidden' => 'permission', 'tool_not_bound' => 'permission'
  }.freeze
  SAFETY_KINDS = %w[moderation prompt_injection credentials custom_rule].freeze
  ACTION_LABELS = (Captain::DoneActions::APPOINTMENT_LABELS.values + Captain::DoneActions::PENDING_APPOINTMENT_LABELS.values +
                   Captain::DoneActions::DEAL_LABELS.values +
                   Captain::DoneActions::TASK_LABELS.values + Captain::DoneActions::COMPANY_LABELS.values +
                   [Captain::DoneActions::PATIENT_LABEL]).freeze

  def self.done_actions(conversation)
    entries = Array(conversation.additional_attributes.to_h.dig('captain_agent_session', 'done'))
    entries.first(LIMIT).filter_map do |entry|
      label = entry.to_h['label'].to_s
      label if ACTION_LABELS.include?(label)
    end
  end

  def self.bounded_text(value, byte_limit)
    value.to_s.byteslice(0, byte_limit).to_s.scrub
  end

  def self.clinic_instruction(assistant, text)
    # Resolve the same $ and @ syntax as the agent prompt. An empty patient state prevents
    # personal fields and internal IDs from being copied into the classification request.
    resolved = assistant.resolve_prompt_texts({ instruction: text.to_s }, {}, bound_tool_ids: []).fetch(:instruction)
    bounded_text(resolved, INSTRUCTION_LIMIT)
  end

  def self.safety_kind(reason)
    case reason.to_s
    when 'prompt_injection' then 'prompt_injection'
    when 'sensitive_info' then 'credentials'
    when 'custom_blocklist' then 'custom_rule'
    else 'moderation'
    end
  end

  def self.record_tool(context, tool_name, result)
    facts = context[:outcome_facts] ||= { 'faq_lookups' => [], 'tool_failures' => [], 'safety_blocks' => [] }
    name = Captain::Runtime::ToolFailure.canonical_name(tool_name)
    record_faq(facts, result, context) if name == 'faq_lookup'
    record_failure(facts, result, name)
    facts.each_value { |items| items.replace(items.last(LIMIT)) }
  rescue StandardError
    # Missing classification facts must not alter a tool's result.
    nil
  end

  def self.record_faq(facts, result, context)
    details = Captain::Runtime::ToolFailure.facts(result)
    return if faq_unavailable?(details, context) && details['result'] == 'not_found'

    answer = details['result'].to_s
    facts['faq_lookups'] << answer if answer.in?(%w[found not_found])
  end
  private_class_method :record_faq

  # A lookup that ran degraded (the semantic search was not available) found nothing for lack of a search, not for lack of an answer.
  # The answer the model reads has no retrieval trace, so the tool leaves the fact in the run context (captain_faq_outcome); a result
  # that still carries a trace (a simulated Playground lookup) is read as before.
  def self.faq_unavailable?(details, context)
    return true if details.dig('retrieval_trace', 'fallback_reason').to_s.in?(Captain::Tools::FaqLookupTool::UNAVAILABLE_REASONS)

    outcome = context.to_h[:captain_faq_outcome].to_h
    outcome[:unavailable] == true && outcome[:result] == details['result']
  end
  private_class_method :faq_unavailable?

  def self.record_failure(facts, result, tool_name = nil)
    info = Captain::Runtime::ToolFailure.describe(result)
    unless info[:failure]
      facts['tool_failures'] << 'calendar_unavailable' if degraded_availability?(tool_name, result)
      return
    end

    code = info[:failure_reason] || info[:reason] || info[:code]
    kind = FAILURE_KINDS[code] || (info[:stage] == 'tool_results' ? 'policy' : 'tool_error')
    facts['tool_failures'] << kind
    record_safety(facts, info[:stage], code)
  end
  private_class_method :record_failure

  def self.degraded_availability?(tool_name, result)
    return false unless AVAILABILITY_TOOLS.include?(tool_name.to_s)

    details = Captain::Runtime::ToolFailure.facts(result)
    degraded_block?(details) ||
      degraded_block?(details['specialists']) ||
      Array(details['results']).any? { |item| degraded_block?(item) }
  end
  private_class_method :degraded_availability?

  def self.degraded_block?(block)
    return false unless block.is_a?(Hash)

    block['availability'] == 'degraded' || block.dig('availability', 'status') == 'degraded'
  end
  private_class_method :degraded_block?

  def self.record_safety(facts, stage, code)
    return unless stage.in?(%w[tool_arguments tool_results])
    return unless code.in?(%w[prompt_injection sensitive_info custom_blocklist moderation_flagged])

    facts['safety_blocks'] << safety_kind(code)
  end
  private_class_method :record_safety

  def self.from_run(context, response = nil)
    facts = context.to_h[:outcome_facts].to_h.deep_stringify_keys
    safety = Array(facts['safety_blocks'])
    safety << (response.to_h['safety_block'] || 'moderation') if response.to_h['moderation_blocked'] == true
    safety << 'custom_rule' if response.to_h['custom_guardrail'].is_a?(Hash)
    {
      'faq_lookups' => Array(facts['faq_lookups']).last(LIMIT),
      'tool_failures' => Array(facts['tool_failures']).last(LIMIT),
      'safety_blocks' => safety.select { |kind| SAFETY_KINDS.include?(kind) }.last(LIMIT)
    }
  end

  def initialize(transition, snapshot)
    @transition = transition
    @snapshot = snapshot
  end

  def input
    data = { public_reply_sent: public_reply_sent?, staff_notes: staff_notes,
             done_actions: Array(@snapshot['done_actions']).last(LIMIT) }.merge(run_fact_lists)
    data[:handoff_reason] = self.class.bounded_text(@transition.metadata['outcome_reason_explanation'], NOTE_LIMIT) if @snapshot['type'] == 'handoff'
    if @snapshot['type'] == 'completion'
      data[:clinic_instruction] = self.class.clinic_instruction(@transition.actor, @snapshot['clinic_instruction_text'])
    end
    data
  end

  private

  def run_fact_lists
    facts = @transition.metadata['outcome_run_facts'].to_h.deep_stringify_keys
    %w[faq_lookups tool_failures safety_blocks].to_h do |kind|
      [kind.to_sym, Array(facts[kind]).last(LIMIT)]
    end
  end

  def run_messages
    @transition.conversation.messages.where(account_id: @transition.account_id)
               .where('id > ? AND id <= ?', @snapshot['run_start_message_id'].to_i, @snapshot['message_id_cutoff'].to_i)
  end

  def public_reply_sent?
    run_messages.exists?(private: false, message_type: :outgoing, sender: @transition.actor)
  end

  def staff_notes
    scope = note_scope.where('id > ? AND created_at <= ?', @snapshot['run_start_message_id'].to_i, note_end_time)
    next_incoming_id = @transition.conversation.messages.incoming.where('created_at > ?', @transition.created_at).minimum(:id)
    scope = scope.where('id < ?', next_incoming_id) if next_incoming_id
    scope.reorder(id: :desc).limit(LIMIT).pluck(:content).reverse.filter_map do |note|
      self.class.bounded_text(note, NOTE_LIMIT) if note.present?
    end
  end

  def note_end_time
    # Platform notes can be written inside the status transaction just after its transition.
    end_time = @transition.created_at + 30.seconds
    next_transition_at = @transition.conversation.status_transitions.where('id > ?', @transition.id).minimum(:created_at)
    [end_time, next_transition_at].compact.min
  end

  def note_scope
    @transition.conversation.messages.where(account_id: @transition.account_id, private: true,
                                            message_type: :outgoing, sender: @transition.actor)
  end
end
