# frozen_string_literal: true

# The choices of a system prompt of the platform (the rules added to the prompt of every AI agent): the group it is shown
# in (the group is what an account sees in the settings of its agent) and the place of the prompt where it is put. Both are
# chosen from a list with Russian names: a group typed by hand opens a new group, a place with a typo turns the rule into an
# ordinary one. The stored values are the ones of Captain::Assistant (English group names, codes of the places), so what is
# stored does not change.
#
#   SuperAdmin::SystemPromptOptions.groups # => [['Strict rules', 'Строгие правила'], ...]
#   SuperAdmin::SystemPromptOptions.slots  # => [['', 'Обычное правило'], ['assistant_identity', 'Агент: кто он такой'], ...]
module SuperAdmin::SystemPromptOptions
  SCOPE = 'super_admin.app_config.captain.prompts'
  GROUP_KEYS = {
    Captain::Assistant::RULE_GROUP_STRICT => 'strict',
    Captain::Assistant::RULE_GROUP_CONVERSATION => 'conversation',
    Captain::Assistant::RULE_GROUP_RESTRICTIONS => 'restrictions',
    Captain::Assistant::RULE_GROUP_ASSISTANT_STRUCTURE => 'assistant_structure',
    Captain::Assistant::RULE_GROUP_SCENARIO_STRUCTURE => 'scenario_structure',
    Captain::Assistant::RULE_GROUP_RUNTIME_CONTEXT => 'runtime_context'
  }.freeze

  module_function

  # [[stored name, Russian name], ...]
  def groups
    GROUP_KEYS.map { |value, key| [value, I18n.t("#{SCOPE}.group_names.#{key}")] }
  end

  # [[code of the place, Russian name], ...]: the plain rule first
  def slots
    plain = [['', I18n.t("#{SCOPE}.slot_names.plain")]]
    plain + Captain::Assistant::SYSTEM_TEMPLATE_SLOT_LABELS.keys.map { |code| [code, I18n.t("#{SCOPE}.slot_names.#{code}")] }
  end

  def group_values
    GROUP_KEYS.keys
  end

  def slot_values
    Captain::Assistant::SYSTEM_TEMPLATE_SLOT_LABELS.keys
  end
end
