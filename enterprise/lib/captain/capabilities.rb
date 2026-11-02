# frozen_string_literal: true

# Versioned binding source. Once present, legacy tool_access and prompt mentions never grant tools.
module Captain::Capabilities
  VERSION = 1
  KEY = 'capabilities'
  SNAPSHOT_KEY = 'capabilities_migration'
  BOOLEANS = [true, false].freeze

  module_function

  def configured?(config)
    config.is_a?(Hash) && config.key?(KEY)
  end

  def scope(config, name)
    value = config.to_h[KEY]
    return {} unless valid?(value)

    value.fetch('scopes').fetch(name.to_s, {})
  end

  def valid?(value)
    return false unless value.is_a?(Hash) && value['version'] == VERSION && value['scopes'].is_a?(Hash)
    return false unless value.keys.sort == %w[scopes version]

    value['scopes'].keys.sort == Captain::ToolAccess::SCOPE_ORDER.sort && value['scopes'].values.all? { |settings| valid_scope?(settings) }
  end

  def valid_scope?(settings)
    return false unless settings.is_a?(Hash) && BOOLEANS.include?(settings['enabled']) && settings['tool_ids'].is_a?(Array)
    return false unless settings.keys.sort == %w[enabled tool_ids]

    settings['tool_ids'].all? { |id| id.is_a?(String) && id.present? }
  end

  def digest(value)
    Digest::SHA256.hexdigest(JSON.generate(sorted_value(value)))
  end

  def sorted_value(value)
    return value.map { |item| sorted_value(item) } if value.is_a?(Array)
    return value unless value.is_a?(Hash)

    value.stringify_keys.sort.to_h.transform_values { |item| sorted_value(item) }
  end

  # Creation always starts on the canonical source. Only explicit selected IDs
  # are converted; prompt mentions never initialize grants. Existing rows are untouched.
  def initialize_config(config)
    result = config.to_h.deep_stringify_keys.deep_dup
    return result if configured?(result)

    canonical = { 'version' => VERSION, 'scopes' => {
      'agent' => { 'enabled' => true, 'tool_ids' => [] },
      'assistant' => { 'enabled' => false, 'tool_ids' => [] }
    } }
    canonical = canonical_alias({ KEY => canonical }, result.delete('tool_access')) if result.key?('tool_access')
    result.merge(KEY => canonical)
  end

  def normalize_updates(current_config, incoming_config, creating: false)
    incoming = incoming_config.deep_stringify_keys.deep_dup
    if incoming.key?(KEY)
      validate_canonical_update!(current_config, incoming, creating: creating)
    elsif configured?(current_config) && incoming.key?('tool_access')
      incoming[KEY] = canonical_alias(current_config, incoming.delete('tool_access'))
    end
    incoming
  end

  def validate_canonical_update!(current, incoming, creating:)
    raise_violation('ambiguous_capabilities', %w[config.capabilities config.tool_access]) if incoming.key?('tool_access')
    raise_violation('invalid_capabilities', ['config.capabilities']) unless valid?(incoming[KEY])
    raise_violation('capability_migration_required', ['config.capabilities']) unless configured?(current) || creating
  end

  def canonical_alias(current, raw)
    raise_violation('invalid_capabilities', ['config.tool_access']) unless raw.is_a?(Hash)

    scopes = current.fetch(KEY).fetch('scopes').deep_dup
    raw.each do |name, settings|
      raise_violation('invalid_capabilities', ['config.tool_access']) unless settings.is_a?(Hash)

      scopes[name] = scopes.fetch(name, {}).merge(settings)
    end
    canonical = { 'version' => VERSION, 'scopes' => scopes }
    raise_violation('invalid_capabilities', ['config.tool_access']) unless valid?(canonical)

    canonical
  end

  def raise_violation(code, fields)
    raise Captain::AssistantConfigContract::Violation.new(code, fields)
  end
end
