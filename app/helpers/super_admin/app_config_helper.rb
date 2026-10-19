# frozen_string_literal: true

# Helpers of the config pages of the super admin (app_config and settings views).
module SuperAdmin::AppConfigHelper
  DIAGNOSTICS_SCOPE = 'super_admin.app_config.captain.diagnostics'

  def app_config_page_title(config)
    SuperAdmin::AppConfigLabels.page_title(config)
  end

  def app_config_title(key, definition = nil)
    SuperAdmin::AppConfigLabels.title(key, definition)
  end

  def app_config_hint(key, definition = nil)
    SuperAdmin::AppConfigLabels.hint(key, definition)
  end

  # The control a setting is edited with, by its type in installation_config.yml (see the `editor` partial)
  def app_config_editor_kind(key, definition = nil)
    return :prompts if key == Captain::Assistant::GLOBAL_SYSTEM_PROMPTS_INSTALLATION_CONFIG

    definition = definition.to_h
    return :secret if SuperAdmin::InstallationConfigs.secret?(key, definition)

    case definition['type']
    when 'boolean' then :boolean
    when 'code' then :textarea
    when 'select' then definition['options'].present? ? :select : :text
    else :text
    end
  end

  # The text a stored value shows as in a text field or a textarea: a JSON object or list as readable JSON
  def app_config_field_value(value)
    case value
    when nil then nil
    when String then value
    when Hash, Array then JSON.pretty_generate(value)
    else value.to_s
    end
  end

  # An <option> of a list of models. The text is the whole option for a list without a script; the data attributes are what the
  # searchable list draws (name, price, what the model can do, the company, the mark of a model the list does not offer).
  def ai_model_option(option, selected_value)
    content_tag(
      :option, option.label,
      value: option.id, selected: option.id == selected_value,
      data: { name: option.name, price: option.price_text, badges: option.badges.join(','), provider: option.provider, note: option.note.presence }
    )
  end

  # The option «Встроенная: GPT-6 Luna» (an empty value: the platform decides)
  def ai_builtin_option(choices, selected)
    label = choices.builtin_id ? t('super_admin.app_config.captain.models.builtin_option', name: choices.builtin_name) : t('super_admin.app_config.captain.models.builtin_unknown')
    content_tag(:option, label, value: '', selected: selected.blank?, data: { name: label, kind: 'builtin' })
  end

  # The readable name of a model id, «встроенная» for none
  def ai_model_name(model_id)
    SuperAdmin::AiModelOptions.name_of(model_id) || t('super_admin.app_config.captain.status.was_builtin')
  end

  # The Russian name of a status of the OpenRouter diagnostics (`scope` is key, credits, refresh or source); a status the
  # list does not know is shown as it came.
  def diagnostics_status(scope, value)
    return t("#{DIAGNOSTICS_SCOPE}.not_available") if value.blank?

    value = 'fallback' if scope.to_s == 'source' && value.to_s == Llm::OpenRouterModelCatalog::FALLBACK_SOURCE
    t("#{DIAGNOSTICS_SCOPE}.statuses.#{scope}.#{value}", default: value.to_s)
  end

  # A moment in Astana time; «никогда» when there is none
  def diagnostics_time(time)
    super_admin_time(time) || t("#{DIAGNOSTICS_SCOPE}.never")
  end

  def diagnostics_amount(value)
    number_with_precision(value.to_f, precision: 2, delimiter: ' ', separator: ',')
  end

  # A counter: whole number, a space between thousands
  def diagnostics_count(value)
    super_admin_number(value.to_i)
  end
end
