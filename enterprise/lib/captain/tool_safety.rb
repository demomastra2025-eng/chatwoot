# frozen_string_literal: true

class Captain::ToolSafety
  # Runtime guardrails (prompt-injection and sensitive-info patterns) scan what a customer or the model sends in
  # (stage input) and what the agent says (stages output / final_output). On tool data they scan only EXTERNAL tools:
  # tools that bring third-party content into the run (web search, web page reading, integrations, clinic-defined custom
  # HTTP tools, MCP tools) or send data outside, which includes tools that deliver model-written text to a customer
  # (send_message_to_conversation, edit_message, create_touch): that text is a second reply channel and the output stage
  # reads only the final reply. Built-in system tools (scheduling, FAQ lookup, contacts, deals, tasks, notes, labels,
  # handoff, plan_request ...) only read and write the workspace's own records, so scanning them adds false positives and
  # no protection.
  #
  # `external_tool?` is the single decision point and it fails closed: a tool is skipped only when it is positively known
  # to be a built-in system tool; anything unrecognised (an unregistered class, a test double, a future provider) is
  # treated as external.
  #
  # A new built-in tool is a system tool as soon as it is registered in Captain::ToolRegistry, because that is how it is
  # selected and bound for an agent. Do nothing more for it to be skipped. If the new tool returns third-party content,
  # calls outside services or delivers model-written text to a customer or an outside system, register it with
  # `external_content: true` and its arguments and results stay scanned.
  EXTERNAL_PROVIDERS = %w[custom mcp openapi skill_script].freeze
  EXTERNAL_SOURCE_TYPES = %w[custom mcp skill].freeze

  class << self
    def check_arguments!(feature:, arguments:, account: nil, preferences: nil)
      Llm::SafetyPolicy.check!(
        feature: feature,
        stage: :tool_arguments,
        content: arguments,
        account: account,
        preferences: preferences
      )
    end

    def check_result!(feature:, result:, account: nil, preferences: nil)
      Llm::SafetyPolicy.check!(
        feature: feature,
        stage: :tool_results,
        content: result,
        account: account,
        preferences: preferences
      )
    end

    def blocked_message(stage:, error:)
      detail =
        case error
        when Llm::SafetyPolicy::UnavailableError
          'because safety policy is unavailable'
        else
          'by safety policy'
        end

      prefix =
        case stage.to_sym
        when :tool_results
          'Tool result blocked'
        else
          'Tool arguments blocked'
        end

      "ERROR: #{prefix} #{detail}"
    end

    # True when the guardrails must scan this tool's arguments and results. `tool` is the runtime tool object
    # (the instance an agent calls), not its registry hash.
    def external_tool?(tool)
      return true if declared_external?(tool)

      !built_in_system_tool?(tool)
    rescue StandardError => e
      Rails.logger.warn("[CAPTAIN][ToolSafety] Treating tool as external after classification error: #{e.class}: #{e.message}")
      true
    end

    private

    def declared_external?(tool)
      return true if external_tool_classes.any? { |tool_class| tool.is_a?(tool_class) }

      metadata = Llm::ToolRiskPolicy.metadata_for(tool)
      truthy?(metadata[:external_content]) || truthy?(metadata[:custom]) ||
        EXTERNAL_PROVIDERS.include?(metadata[:provider].to_s) || EXTERNAL_SOURCE_TYPES.include?(metadata[:source_type].to_s)
    end

    def built_in_system_tool?(tool)
      return true if coordination_tool_classes.any? { |tool_class| tool.is_a?(tool_class) }

      definition = registered_definition(tool)
      definition.present? && !definition.external_content?
    end

    # Custom HTTP and MCP tools are rebuilt per run (HttpTool subclasses carry the clinic's slug as their name), so they
    # are recognised by class and never by a name that could collide with a built-in id.
    def external_tool_classes
      [Captain::Tools::HttpTool, Captain::Tools::McpTool, Captain::Tools::SkillScriptTool]
    end

    # Hand-over, task queue and request plan only write the run's own coordination state.
    def coordination_tool_classes
      [Captain::Runtime::HandoffTool, Captain::Runtime::TaskQueueTool, Captain::Runtime::PartPlanTool]
    end

    def registered_definition(tool)
      return adapter_definition(tool) if tool.is_a?(Captain::Tools::Agent::AccountToolAdapter)

      Captain::ToolRegistry.definition_for_class(tool.class, scope_name: Captain::ToolAccess::SCOPE_AGENT)
    end

    # One adapter class serves many registry ids, so it is resolved by its id.
    def adapter_definition(adapter)
      definition = Captain::ToolRegistry.definition_for(adapter.name)
      definition if definition&.agent_tool_class == Captain::Tools::Agent::AccountToolAdapter
    end

    def truthy?(value)
      ActiveModel::Type::Boolean.new.cast(value) == true
    end
  end
end
