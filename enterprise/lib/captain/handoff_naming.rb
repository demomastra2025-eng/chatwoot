# frozen_string_literal: true

module Captain::HandoffNaming
  TOOL_PREFIX = 'handoff_to_'
  MAX_TOOL_NAME_LENGTH = 60
  MAX_TARGET_NAME_LENGTH = MAX_TOOL_NAME_LENGTH - TOOL_PREFIX.length

  module_function

  def normalize_target_name(value)
    value.to_s.parameterize(separator: '_')
  end

  def tool_name_for(target_name)
    "#{TOOL_PREFIX}#{normalize_target_name(target_name)}"
  end
end
