# frozen_string_literal: true

class Captain::Assistant::MergeLegacyRulesService
  MIGRATION_KEY = 'main_prompt_rules_migration'
  VERSION = 1

  def initialize(assistant:)
    @assistant = assistant
  end

  def perform
    @assistant.with_lock do
      attributes = self.class.attributes_for(@assistant)
      @assistant.update_columns(attributes.merge(updated_at: Time.current)) if attributes.present?
    end
  end

  def self.attributes_for(assistant)
    config = assistant.config.to_h.deep_stringify_keys.deep_dup
    return {} if config.dig(MIGRATION_KEY, 'version') == VERSION && !legacy_values?(assistant, config)

    prompt = assistant.description.to_s
    entries = rule_entries(assistant, config)
    active, disabled = entries.partition { |entry| entry[:enabled] }
    active.each { |entry| prompt = append_once(prompt, entry[:content]) }
    archived = Array(config.dig(MIGRATION_KEY, 'archived_rules')) + disabled.map { |entry| entry[:content] }

    config.delete('rules')
    config.delete('skills')
    tool_access = config['tool_access'].is_a?(Hash) ? config['tool_access'] : {}
    tool_access.each_value do |scope|
      next unless scope.is_a?(Hash) && scope['tool_ids'].is_a?(Array)

      scope['tool_ids'].reject! { |id| id.to_s.start_with?('skill_script_') }
    end
    config[MIGRATION_KEY] = { 'version' => VERSION, 'archived_rules' => archived.uniq }
    { description: prompt, config: config, response_guidelines: [], guardrails: [] }
  end

  def self.legacy_values?(assistant, config)
    config.key?('rules') || config.key?('skills') || Array(assistant[:response_guidelines]).any? || Array(assistant[:guardrails]).any?
  end

  def self.rule_entries(assistant, config)
    entries = Array(config['rules']).filter_map do |entry|
      raw = entry.is_a?(Hash) ? entry.stringify_keys : { 'content' => entry.to_s }
      content = raw['content'].to_s
      next if content.blank? || generated_system_rule?(raw)

      { content: content, enabled: !raw.key?('enabled') || ActiveModel::Type::Boolean.new.cast(raw['enabled']) }
    end
    entries.concat([*Array(assistant[:response_guidelines]), *Array(assistant[:guardrails])].filter_map do |content|
      text = content.is_a?(Hash) ? content.with_indifferent_access.fetch(:content, content.to_json).to_s : content.to_s
      { content: text, enabled: true } if text.present?
    end)
    entries.group_by { |entry| entry[:content].strip }.map do |_content, duplicates|
      duplicates.max_by { |entry| entry[:content].length }.merge(enabled: duplicates.any? { |entry| entry[:enabled] })
    end
  end

  def self.generated_system_rule?(entry)
    return false unless entry['type'] == 'system'
    return false if ActiveModel::Type::Boolean.new.cast(entry['editable'])

    Captain::Assistant::DEFAULT_SYSTEM_RULES.any? do |rule|
      rule[:id].to_s == entry['id'].to_s && rule[:content].to_s == entry['content'].to_s.strip
    end
  end

  def self.append_once(prompt, content)
    return prompt if content.blank? || contains_instruction?(prompt, content)
    return content if prompt.blank?

    "#{prompt}\n\n#{content}"
  end

  def self.contains_instruction?(prompt, content)
    prompt.match?(/(?:\A|\n[ \t]*\n)#{Regexp.escape(content)}(?:\n[ \t]*\n|\z)/)
  end

  private_class_method :legacy_values?, :rule_entries, :generated_system_rule?, :append_once, :contains_instruction?
end
