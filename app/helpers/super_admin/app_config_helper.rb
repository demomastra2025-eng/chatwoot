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
