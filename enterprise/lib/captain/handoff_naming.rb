# frozen_string_literal: true

require 'digest'

module Captain::HandoffNaming
  TOOL_PREFIX = 'handoff_to_'
  MAX_TOOL_NAME_LENGTH = 60
  MAX_TARGET_NAME_LENGTH = MAX_TOOL_NAME_LENGTH - TOOL_PREFIX.length

  module_function

  def normalize_target_name(value)
    value.to_s.parameterize(separator: '_')
  end

  def safe_target_name(value, fallback_prefix: 'assistant', record_id: nil)
    normalized_name = normalize_target_name(value)
    normalized_name = fallback_target_name(value, fallback_prefix, record_id) if normalized_name.blank?

    truncate_target_name(
      normalized_name,
      source: value,
      fallback_prefix: fallback_prefix
    )
  end

  def tool_name_for(target_name)
    "#{TOOL_PREFIX}#{safe_target_name(target_name)}"
  end

  def fallback_target_name(value, fallback_prefix, record_id)
    return "#{normalized_prefix(fallback_prefix)}_#{record_id}" if record_id.present?

    "#{normalized_prefix(fallback_prefix)}_#{stable_suffix_for(value)}"
  end

  def truncate_target_name(target_name, source:, fallback_prefix:)
    return target_name if target_name.length <= MAX_TARGET_NAME_LENGTH

    suffix = stable_suffix_for(source)
    max_base_length = MAX_TARGET_NAME_LENGTH - suffix.length - 1
    truncated_base = target_name[0, max_base_length].to_s.sub(/_+\z/, '')

    base =
      truncated_base.presence ||
      normalized_prefix(fallback_prefix)[0, max_base_length]

    "#{base}_#{suffix}"
  end

  def normalized_prefix(value)
    normalize_target_name(value).presence || 'assistant'
  end

  def stable_suffix_for(value)
    Digest::SHA1.hexdigest(value.to_s)[0, 12]
  end
end
