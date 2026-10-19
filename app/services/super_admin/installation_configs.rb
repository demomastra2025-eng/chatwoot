# frozen_string_literal: true

# What the super admin may show of the installation parameters (InstallationConfig rows) and where each one is edited.
#
# * A secret (a key, a token, a password, a credentials file) is NEVER printed, not even in part: the pages say only
#   whether it is set. What counts as a secret: the type `secret` in config/installation_config.yml, a name that ends
#   like one (…_SECRET, …_API_KEY, …_TOKEN, FIREBASE_CREDENTIALS), a webhook URL (a Discord or Slack webhook is a
#   credential itself: whoever has the URL can post), and any row the catalogue does not know (an unknown row can
#   hold anything).
# * Another value is shown as it is, cut to VALUE_LIMIT characters.
# * Every parameter that a settings page edits knows that page (`page_for`), so the read-only list links to it.
module SuperAdmin::InstallationConfigs
  # The one thing a screen shows of a value: a kind and a text
  Display = Struct.new(:kind, :text, keyword_init: true)

  SECRET_NAME_PATTERN = /(SECRET|PASSWORD|PASSPHRASE|API_KEY|PRIVATE_KEY|ACCESS_KEY|SERVER_KEY|CREDENTIALS?|HMAC_KEY|_TOKEN|WEBHOOK_URL)\z/
  VALUE_LIMIT = 120
  CATALOGUE_FILES = [
    Rails.root.join('config/installation_config.yml'),
    Rails.root.join('enterprise/config/premium_installation_config.yml')
  ].freeze

  module_function

  # The catalogue of the parameters: the entries of config/installation_config.yml and of the premium file next to it,
  # by name: { 'FB_APP_ID' => { 'display_title' => ..., 'type' => ... } }
  def definitions
    @definitions ||= CATALOGUE_FILES.each_with_object({}) do |path, result|
      next unless File.exist?(path)

      Array(YAML.safe_load_file(path)).each { |entry| result[entry['name']] = entry.except('name') }
    end.freeze
  end

  def known?(name)
    definitions.key?(name.to_s)
  end

  # definition: the entry of the catalogue when the caller has it already (it is looked up otherwise)
  def secret?(name, definition = nil)
    definition ||= definitions[name.to_s]
    type = definition.to_h['type']
    return false if type == 'boolean'

    type == 'secret' || name.to_s.match?(SECRET_NAME_PATTERN)
  end

  # The settings page (the `config` param of /super_admin/app_config) that edits the parameter, or nil
  def page_for(name)
    page_map[name.to_s]
  end

  # The page a parameter is edited on, by parameter name: { 'FB_APP_ID' => 'facebook', ... }
  def page_map
    @page_map ||= begin
      pages = SuperAdmin::AppConfigsController::APP_CONFIG_MAPPING.merge('general' => SuperAdmin::AppConfigsController::DEFAULT_ALLOWED_CONFIGS)
      if defined?(Enterprise::SuperAdmin::AppConfigsController::CUSTOM_BRANDING_CONFIG_KEYS)
        pages = pages.merge('custom_branding' => Enterprise::SuperAdmin::AppConfigsController::CUSTOM_BRANDING_CONFIG_KEYS)
      end
      pages.each_with_object({}) do |(page, names), result|
        names.each { |name| result[name] ||= page }
      end.freeze
    end
  end

  # How a row is shown: :secret_set / :secret_unset (a secret), :hidden (a row the catalogue does not know: it can hold
  # anything), :value (with text) or :empty
  def display(config)
    return Display.new(kind: :empty, text: nil) if config.nil?

    kind = display_kind(config.name, !(config.value.nil? || config.value == ''))
    Display.new(kind: kind, text: (printable(config.value).truncate(VALUE_LIMIT) if kind == :value))
  end

  def display_kind(name, set)
    return set ? :secret_set : :secret_unset if secret?(name)
    return :empty unless set

    known?(name) ? :value : :hidden
  end

  def printable(value)
    case value
    when String then value
    when Hash, Array then value.to_json
    else value.to_s
    end
  end
end
