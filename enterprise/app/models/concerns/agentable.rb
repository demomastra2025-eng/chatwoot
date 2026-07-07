module Concerns::Agentable
  extend ActiveSupport::Concern

  def agent
    Captain::Runtime::Agent.new(
      name: agent_name,
      instructions: ->(context) { agent_instructions(context) },
      tools: time_agent_phase('agent_tools') { agent_tools },
      model: time_agent_phase('agent_model') { agent_model },
      temperature: time_agent_phase('agent_temperature') { agent_temperature },
      response_schema: time_agent_phase('agent_response_schema') { agent_response_schema }
    )
  end

  def agent_instructions(context = nil)
    state = context&.context&.[](:state) || {}
    prompt_state = state[:prompt_context] || {}
    enhanced_context = time_agent_phase('prompt_context') { prompt_context_for_runtime_state(state) }.merge(default_prompt_runtime_context)

    if state.present?
      explicit_prompt_context = state.key?(:prompt_context)
      conversation_data = explicit_prompt_context ? prompt_state[:conversation].presence : state[:conversation].presence
      contact_data = explicit_prompt_context ? prompt_state[:contact].presence : state[:contact].presence
      deal_data = explicit_prompt_context ? prompt_state[:deal].presence : state[:deal].presence
      task_data = explicit_prompt_context ? prompt_state[:task].presence : state[:task].presence
      appointment_data = explicit_prompt_context ? prompt_state[:appointment].presence : state[:appointment].presence
      communication_thread_data = explicit_prompt_context ? prompt_state[:communication_thread].presence : state[:communication_thread].presence
      visible_fields =
        if explicit_prompt_context
          prompt_state[:visible_fields] || {}
        else
          {
            conversation: Array(conversation_data&.keys).map(&:to_s),
            contact: Array(contact_data&.keys).map(&:to_s),
            deal: Array(deal_data&.keys).map(&:to_s),
            task: Array(task_data&.keys).map(&:to_s),
            appointment: Array(appointment_data&.keys).map(&:to_s)
          }
        end

      enhanced_context = enhanced_context.merge(
        runtime_clock: state[:runtime_clock] || {},
        reply_window: state[:reply_window] || {},
        conversation: conversation_data,
        contact: contact_data,
        deal: deal_data,
        task: task_data,
        appointment: appointment_data,
        communication_thread: communication_thread_data,
        campaign: state[:campaign] || {},
        conversation_visible_fields: visible_fields[:conversation] || [],
        contact_visible_fields: visible_fields[:contact] || [],
        deal_visible_fields: visible_fields[:deal] || [],
        task_visible_fields: visible_fields[:task] || [],
        appointment_visible_fields: visible_fields[:appointment] || [],
        **runtime_custom_attribute_label_context(
          explicit_prompt_context: explicit_prompt_context,
          prompt_state: prompt_state
        )
      )
    end

    if respond_to?(:resolve_runtime_prompt_context, true)
      enhanced_context = time_agent_phase('resolve_runtime_prompt_context') do
        resolve_runtime_prompt_context(enhanced_context, prompt_state)
      end
    end

    time_agent_phase('prompt_render') { Captain::PromptRenderer.render(template_name, enhanced_context.with_indifferent_access) }
  end

  private

  def agent_name
    raise NotImplementedError, "#{self.class} must implement agent_name"
  end

  def template_name
    self.class.name.demodulize.underscore
  end

  def agent_tools
    []  # Default implementation, override if needed
  end

  def agent_temperature
    (temperature.presence || 1).to_f
  end

  def agent_model
    Llm::Config.model_for(
      feature: :assistant,
      account: respond_to?(:account) ? account : nil,
      fallback: LlmConstants::DEFAULT_MODEL
    )
  end

  def agent_response_schema
    Captain::ResponseSchema
  end

  def prompt_context
    raise NotImplementedError, "#{self.class} must implement prompt_context"
  end

  def default_prompt_runtime_context
    {
      conversation: nil,
      contact: nil,
      deal: nil,
      task: nil,
      appointment: nil,
      communication_thread: nil,
      campaign: {},
      runtime_clock: {},
      reply_window: {},
      conversation_visible_fields: [],
      contact_visible_fields: [],
      deal_visible_fields: [],
      task_visible_fields: [],
      appointment_visible_fields: [],
      contact_custom_attribute_labels: {},
      conversation_custom_attribute_labels: {},
      deal_custom_attribute_labels: {},
      task_custom_attribute_labels: {},
      appointment_custom_attribute_labels: {}
    }
  end

  def prompt_context_for_runtime_state(state = {})
    return prompt_context unless voice_ai_runtime_state?(state)

    Rails.cache.fetch(voice_prompt_context_cache_key, expires_in: 2.minutes) { prompt_context }
  rescue StandardError
    prompt_context
  end

  def voice_ai_runtime_state?(state)
    state.to_h[:source].to_s == 'voice_ai' || state.to_h['source'].to_s == 'voice_ai'
  end

  def voice_prompt_context_cache_key
    [
      'captain',
      'voice_prompt_context',
      self.class.name,
      respond_to?(:id) ? id : nil,
      respond_to?(:cache_key_with_version) ? cache_key_with_version : nil,
      respond_to?(:account_id) ? account_id : nil
    ].compact.join(':')
  end

  def runtime_custom_attribute_label_context(explicit_prompt_context:, prompt_state:)
    label_context =
      if explicit_prompt_context
        scoped_custom_attribute_label_context(prompt_state)
      else
        scoped_custom_attribute_label_context(default_custom_attribute_label_maps)
      end

    default_prompt_runtime_context.slice(
      :contact_custom_attribute_labels,
      :conversation_custom_attribute_labels,
      :deal_custom_attribute_labels,
      :task_custom_attribute_labels,
      :appointment_custom_attribute_labels
    ).merge(label_context)
  end

  def scoped_custom_attribute_label_context(source)
    Captain::ContextFields::SCOPES.each_with_object({}) do |scope, context|
      context[:"#{scope}_custom_attribute_labels"] =
        source[:"#{scope}_custom_attribute_labels"] ||
        source[scope.to_sym] ||
        source[scope.to_s] ||
        {}
    end
  end

  def default_custom_attribute_label_maps
    definitions =
      if respond_to?(:allowed_context_fields)
        allowed_context_fields
      elsif respond_to?(:assistant) && assistant.respond_to?(:allowed_context_fields)
        assistant.allowed_context_fields
      else
        []
      end

    Captain::ContextFields.custom_attribute_label_maps_for_definitions(definitions)
  end

  def time_agent_phase(name)
    started_at = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    yield
  ensure
    duration_ms = ((Process.clock_gettime(Process::CLOCK_MONOTONIC) - started_at) * 1000).round
    if duration_ms >= 250
      Rails.logger.info(
        "[CAPTAIN][Timing] record=#{self.class.name} id=#{respond_to?(:id) ? id : nil} " \
        "phase=#{name} duration_ms=#{duration_ms}"
      )
    end
  end
end
