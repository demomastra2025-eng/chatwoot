# frozen_string_literal: true

# The Russian title and hint of an installation config on the settings pages of the super admin.
#
# The texts live in config/locales/super_admin_settings.ru.yml under `super_admin.app_config.fields.<NAME>`. A config
# without an entry there falls back to the display title and description of config/installation_config.yml (many of
# them are Russian already), and last to its name, so a new config never renders an empty label.
#
#   SuperAdmin::AppConfigLabels.title('FB_APP_ID', definition)  # => "Facebook: ID приложения"
#   SuperAdmin::AppConfigLabels.hint('FB_APP_ID', definition)   # => "Идентификатор приложения Facebook ..."
module SuperAdmin::AppConfigLabels
  SCOPE = 'super_admin.app_config.fields'

  module_function

  # definition: the entry of installation_config.yml for the config (a Hash with string keys), or nil
  def title(key, definition = nil)
    I18n.t("#{SCOPE}.#{key}.title", default: definition.to_h['display_title'].presence || key.to_s)
  end

  # An empty string when the config has no hint
  def hint(key, definition = nil)
    I18n.t("#{SCOPE}.#{key}.hint", default: definition.to_h['description'].to_s)
  end

  # The title of a config page: «Общие параметры», «Модели ИИ», «Facebook и Messenger»
  def page_title(config)
    key = "super_admin.app_config.pages.#{config}"
    return I18n.t(key) if I18n.exists?(key)

    SuperAdmin::NavigationHelper::FEATURE_LABELS.fetch(config.to_s) { config.to_s.humanize }
  end
end
