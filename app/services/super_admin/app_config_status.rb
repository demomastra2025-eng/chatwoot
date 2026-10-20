# frozen_string_literal: true

# The contents of the settings: every settings page with the one line a person needs, «настроено» or «не настроено».
# A page counts as set up when every setting that the connection cannot work without is stored (a secret is only checked
# for being set, never read out). A page that has nothing to connect (the general parameters, the branding) has no status.
#
#   SuperAdmin::AppConfigStatus.new.entries.each { |entry| entry.config; entry.configured } # configured: true, false or nil
class SuperAdmin::AppConfigStatus
  Entry = Struct.new(:config, :group, :configured, keyword_init: true)

  # The settings the connection cannot work without, by page
  REQUIRED = {
    'email' => %w[MAILER_INBOUND_EMAIL_DOMAIN],
    'facebook' => %w[FB_APP_ID FB_APP_SECRET],
    'instagram' => %w[INSTAGRAM_APP_ID INSTAGRAM_APP_SECRET],
    'tiktok' => %w[TIKTOK_APP_ID TIKTOK_APP_SECRET],
    'whatsapp_embedded' => %w[WHATSAPP_APP_ID WHATSAPP_APP_SECRET WHATSAPP_CONFIGURATION_ID],
    'google' => %w[GOOGLE_OAUTH_CLIENT_ID GOOGLE_OAUTH_CLIENT_SECRET],
    'microsoft' => %w[AZURE_APP_ID AZURE_APP_SECRET],
    'slack' => %w[SLACK_CLIENT_ID SLACK_CLIENT_SECRET]
  }.freeze
  # The pages of the contents in the order of the sidebar, by group (the Russian name of a group is in the locale)
  PLATFORM_PAGES = %w[general captain custom_branding].freeze
  CONNECTION_PAGES = %w[email facebook instagram tiktok whatsapp_embedded google microsoft slack].freeze

  # `pages`: the settings pages the installation offers (the ones the sidebar links to); an unavailable page is not listed
  def initialize(pages: nil)
    @pages = pages
  end

  def entries
    platform = PLATFORM_PAGES.select { |config| offered?(config) }.map { |config| entry(config, :platform) }
    connections = CONNECTION_PAGES.select { |config| offered?(config) }.map { |config| entry(config, :connections) }
    platform + connections
  end

  def configured?(config)
    return ai_models_configured? if config == 'captain'

    names = REQUIRED[config]
    return if names.blank?

    names.all? { |name| stored[name].present? }
  end

  private

  def entry(config, group)
    Entry.new(config: config, group: group, configured: configured?(config))
  end

  def offered?(config)
    @pages.nil? || @pages.include?(config) || config == 'captain'
  end

  # The values the settings pages show: the stored rows only (a value that is only in the environment shows as not set,
  # exactly as it does on the page of the setting)
  def stored
    @stored ||= InstallationConfig.where(name: REQUIRED.values.flatten).pluck(:name, :serialized_value).to_h
                                  .transform_values { |serialized| serialized.to_h.with_indifferent_access[:value] }
  end

  def ai_models_configured?
    Llm::Config.installation_provider_available?(Llm::OpenRouterModelCatalog::PROVIDER) || false
  rescue StandardError
    nil
  end
end
