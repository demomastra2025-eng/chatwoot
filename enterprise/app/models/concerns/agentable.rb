module Concerns::Agentable
  extend ActiveSupport::Concern

  def agent
    Agents::Agent.new(
      name: agent_name,
      instructions: ->(context) { agent_instructions(context) },
      tools: agent_tools,
      model: agent_model,
      temperature: temperature.to_f || 0.7,
      response_schema: agent_response_schema
    )
  end

  def agent_instructions(context = nil)
    enhanced_context = prompt_context
    state = context&.context&.[](:state) || {}
    prompt_state = state[:prompt_context] || {}

    if state.present?
      assistant_config = state[:assistant_config]
      assistant_config = assistant_config.with_indifferent_access if assistant_config.respond_to?(:with_indifferent_access)
      assistant_config ||= {}
      explicit_prompt_context = state.key?(:prompt_context)
      legacy_contact_attributes_enabled = ActiveModel::Type::Boolean.new.cast(assistant_config[:feature_contact_attributes])
      context_access_configured = assistant_config.key?(:context_access)
      conversation_data = explicit_prompt_context ? prompt_state[:conversation].presence : state[:conversation].presence
      contact_data =
        if explicit_prompt_context
          if context_access_configured
            prompt_state[:contact].presence
          elsif legacy_contact_attributes_enabled
            prompt_state[:contact].presence || state[:contact].presence
          end
        elsif legacy_contact_attributes_enabled
          state[:contact].presence
        end
      visible_fields = prompt_state[:visible_fields] || {}

      enhanced_context = enhanced_context.merge(
        conversation: conversation_data,
        contact: contact_data,
        campaign: state[:campaign] || {},
        conversation_visible_fields: visible_fields[:conversation] || [],
        contact_visible_fields: visible_fields[:contact] || []
      )
    end

    if respond_to?(:resolve_runtime_prompt_context, true)
      enhanced_context = resolve_runtime_prompt_context(enhanced_context, prompt_state)
    end

    Captain::PromptRenderer.render(template_name, enhanced_context.with_indifferent_access)
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

  def agent_model
    InstallationConfig.find_by(name: 'CAPTAIN_OPEN_AI_MODEL')&.value.presence || LlmConstants::DEFAULT_MODEL
  end

  def agent_response_schema
    Captain::ResponseSchema
  end

  def prompt_context
    raise NotImplementedError, "#{self.class} must implement prompt_context"
  end
end
