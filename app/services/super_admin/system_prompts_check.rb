# frozen_string_literal: true

# The rules of the platform (system prompts) a page sends, read and checked: the JSON of the builder as the rules that are
# stored (five fields each), and the check that the group and the place of every rule come from the lists of
# SuperAdmin::SystemPromptOptions. A group or a place that is not in the lists is allowed for a rule that already has it
# (an old value is not lost), never for a rule that gets it now.
#
#   entries = SuperAdmin::SystemPromptsCheck.parse(params_text) # => [{ 'id' => ..., 'group' => ..., 'content' => ... }] or nil
#   SuperAdmin::SystemPromptsCheck.problem(entries, stored)     # => nil or the Russian message
module SuperAdmin::SystemPromptsCheck
  FIELDS = %i[id type group content slot].freeze
  SCOPE = 'super_admin.app_config.captain.form'

  module_function

  # The rules of the text of the builder; nil when it is not a list of rules
  def parse(value)
    parsed = value.present? ? JSON.parse(value) : []
    parsed.is_a?(Array) ? entries_of(parsed) : nil
  rescue JSON::ParserError
    nil
  end

  # The rules as they are stored: only the five fields, the way Captain::Assistant normalizes them
  def entries_of(raw)
    Captain::Assistant.normalize_installation_system_prompt_entries(raw.is_a?(Array) ? raw : []).map do |entry|
      FIELDS.to_h { |field| [field.to_s, entry[field]] }
    end
  end

  # The Russian message about the first rule whose group or place is not from the lists, or nil
  def problem(entries, stored_raw)
    stored = entries_of(stored_raw).index_by { |entry| entry['id'] }
    entries.each_with_index do |entry, index|
      before = stored[entry['id']].to_h
      message = group_problem(entry, before, index + 1) || slot_problem(entry, before, index + 1)
      return message if message
    end
    nil
  end

  def group_problem(entry, before, number)
    return if SuperAdmin::SystemPromptOptions.group_values.include?(entry['group']) || entry['group'] == before['group']

    I18n.t("#{SCOPE}.group_unknown", number: number, group: entry['group'])
  end

  def slot_problem(entry, before, number)
    slot = entry['slot']
    return if slot.blank? || SuperAdmin::SystemPromptOptions.slot_values.include?(slot) || slot == before['slot']

    I18n.t("#{SCOPE}.slot_unknown", number: number, slot: slot)
  end
end
