# frozen_string_literal: true

require 'digest'

# The names an agent is reached by: the transfer tool of a colleague (transfer_to_agent_<id>) and the keys the runtime and the
# stored traces use for an agent (assistant_<id>; agent_<id> is the same agent as it appears in a tool name).
module Captain::HandoffNaming
  TOOL_PREFIX = 'transfer_to_'
  # The former prefix. Stored traces, histories and monitoring events carry it, so every parser still accepts it.
  LEGACY_TOOL_PREFIX = 'handoff_to_'
  TOOL_PREFIXES = [TOOL_PREFIX, LEGACY_TOOL_PREFIX].freeze
  # What a name that has no Latin letters (a Cyrillic agent name) is replaced with: agent_<id>, or agent_<hash> without an ID.
  FALLBACK_PREFIX = 'agent'
  MAX_TOOL_NAME_LENGTH = 60
  MAX_TARGET_NAME_LENGTH = MAX_TOOL_NAME_LENGTH - TOOL_PREFIXES.map(&:length).max
  AGENT_KEY = /\A(?:assistant|agent)_(\d+)\z/

  module_function

  def normalize_target_name(value)
    value.to_s.parameterize(separator: '_')
  end

  def safe_target_name(value, fallback_prefix: FALLBACK_PREFIX, record_id: nil)
    normalized_name = normalize_target_name(value)
    normalized_name = fallback_target_name(value, fallback_prefix, record_id) if normalized_name.blank?

    truncate_target_name(
      normalized_name,
      source: value,
      fallback_prefix: fallback_prefix
    )
  end

  # An agent that has an ID is reached by it (transfer_to_agent_4): the name is stable, unique and independent of how the agent
  # is spelled, so a Cyrillic or renamed colleague needs no transliteration. One without an ID (a runtime-only agent) is reached by
  # its normalized name.
  def tool_name_for(target_name, record_id: nil)
    target = record_id.present? ? "#{FALLBACK_PREFIX}_#{record_id}" : safe_target_name(target_name)
    "#{TOOL_PREFIX}#{target}"
  end

  # True for the transfer tool of a colleague under either prefix (transfer_to_*, and handoff_to_* in stored data).
  def transfer_tool_name?(tool_name)
    tool_name.to_s.start_with?(*TOOL_PREFIXES)
  end

  # The key of the agent that a transfer tool name points to, under either prefix. "transfer_to_agent_4" and "handoff_to_assistant_4"
  # are both "assistant_4"; any other key (a legacy scenario) is returned as it is. nil for a name that is not a transfer tool.
  def target_key_for(tool_name)
    name = tool_name.to_s
    prefix = TOOL_PREFIXES.find { |item| name.start_with?(item) }
    return unless prefix

    key = name.delete_prefix(prefix)
    id = agent_id_from_key(key)
    id ? "assistant_#{id}" : key.presence
  end

  # The ID in an agent key (assistant_4 or agent_4); nil for every other key.
  def agent_id_from_key(key)
    key.to_s[AGENT_KEY, 1]&.to_i
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
    normalize_target_name(value).presence || FALLBACK_PREFIX
  end

  def stable_suffix_for(value)
    Digest::SHA1.hexdigest(value.to_s)[0, 12]
  end
end
