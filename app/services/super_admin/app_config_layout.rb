# frozen_string_literal: true

# What a config page of the super admin shows of its settings, and where.
#
# The owner is not a developer: a page keeps in view only what he really sets (the keys of an app, a limit, a switch),
# the technical settings (versions of an API, tokens that Meta checks, routing between servers) are folded into the
# block «Для разработчика», a setting that does nothing is not shown at all, and a setting that must not be edited from
# here is shown as text.
#
# This only decides what the page DRAWS. The controller still saves every setting that is sent
# (SuperAdmin::AppConfigsController::APP_CONFIG_MAPPING), and a setting that is not drawn is not sent: its stored value is
# never touched by saving the page.
#
#   page = SuperAdmin::AppConfigLayout.page('facebook', allowed_keys)
#   page.sections.first.keys # => ["FB_APP_ID", "FB_APP_SECRET"]
#   page.developer           # => ["FB_VERIFY_TOKEN", ...]
module SuperAdmin::AppConfigLayout
  # A group of settings in view. `id` names the heading in the locale (super_admin.app_config.layout.sections.<page>.<id>);
  # a group without an id has no heading.
  Section = Struct.new(:id, :keys, keyword_init: true)

  # sections: in view; developer: folded under «Для разработчика» and editable; read_only: shown as text under
  # «Для разработчика»; hidden: not shown (the setting does nothing in OneLink, its stored value stays as it is)
  Page = Struct.new(:config, :sections, :developer, :read_only, :hidden, keyword_init: true) do
    def shown_keys = sections.flat_map(&:keys)

    # The settings the page draws as controls (the ones a save sends)
    def editable_keys = shown_keys + developer

    def all_keys = editable_keys + read_only + hidden

    def developer_block? = developer.any? || read_only.any?
  end

  PAGES = {
    'general' => {
      sections: {
        'signup' => %w[ENABLE_ACCOUNT_SIGNUP HCAPTCHA_SITE_KEY HCAPTCHA_SERVER_KEY],
        'limits' => %w[ACCOUNT_CONVERSATIONS_LIMIT ACCOUNT_NON_WEB_INBOXES_LIMIT ACCOUNT_STORAGE_BYTES_LIMIT MAXIMUM_FILE_UPLOAD_SIZE]
      },
      developer: %w[WEBHOOK_TIMEOUT WIDGET_TOKEN_EXPIRY FIREBASE_PROJECT_ID FIREBASE_CREDENTIALS GRAFANA_OVERVIEW_DASHBOARD GRAFANA_LOGS_DASHBOARD]
    },
    'email' => {
      sections: { nil => %w[ACCOUNT_EMAILS_LIMIT] },
      developer: %w[MAILER_INBOUND_EMAIL_DOMAIN],
      # The tariff limits of letters: the system looks for the name of a tariff that no longer exists, so it never applies
      hidden: %w[ACCOUNT_EMAILS_PLAN_LIMITS]
    },
    'facebook' => {
      sections: { nil => %w[FB_APP_ID FB_APP_SECRET] },
      developer: %w[FB_VERIFY_TOKEN IG_VERIFY_TOKEN FACEBOOK_API_VERSION ENABLE_MESSENGER_CHANNEL_HUMAN_AGENT]
    },
    'instagram' => {
      sections: { nil => %w[INSTAGRAM_APP_ID INSTAGRAM_APP_SECRET] },
      developer: %w[INSTAGRAM_VERIFY_TOKEN INSTAGRAM_API_VERSION ENABLE_INSTAGRAM_CHANNEL_HUMAN_AGENT]
    },
    'tiktok' => {
      sections: { nil => %w[TIKTOK_APP_ID TIKTOK_APP_SECRET] },
      developer: %w[TIKTOK_API_VERSION]
    },
    'whatsapp_embedded' => {
      sections: { nil => %w[WHATSAPP_APP_ID WHATSAPP_APP_SECRET WHATSAPP_CONFIGURATION_ID] },
      developer: %w[
        WHATSAPP_WEBHOOK_VERIFY_TOKEN WHATSAPP_API_VERSION
        WHATSAPP_PROACTIVE_REAUTHORIZATION_ENABLED WHATSAPP_REQUIRE_NON_EXPIRING_SYSTEM_USER_TOKEN
        WHATSAPP_WEBHOOK_PUBLIC_INGRESS_URL WHATSAPP_WEBHOOK_PUBLIC_VERIFY_TOKEN
        WHATSAPP_WEBHOOK_ROUTING_RULES WHATSAPP_WEBHOOK_FORWARD_SECRET WHATSAPP_WEBHOOK_RECEIVER_DESTINATION
      ],
      # Exactly one value is valid (Whatsapp::WebhookIngressRouter::FORWARD_TARGET_CONTRACT): shown, not edited
      read_only: %w[WHATSAPP_WEBHOOK_FORWARD_TARGETS]
    },
    'google' => {
      sections: { nil => %w[GOOGLE_OAUTH_CLIENT_ID GOOGLE_OAUTH_CLIENT_SECRET ENABLE_GOOGLE_OAUTH_LOGIN] },
      # The system never reads it: the return address is built from the address of the platform (see the addresses block)
      hidden: %w[GOOGLE_OAUTH_REDIRECT_URI]
    },
    'microsoft' => { sections: { nil => %w[AZURE_APP_ID AZURE_APP_SECRET] } },
    'slack' => { sections: { nil => %w[SLACK_CLIENT_ID SLACK_CLIENT_SECRET] } },
    'custom_branding' => {
      sections: { nil => %w[BRAND_NAME INSTALLATION_NAME LOGO LOGO_DARK LOGO_THUMBNAIL TERMS_URL PRIVACY_URL] },
      developer: %w[BRAND_URL WIDGET_BRAND_URL DISPLAY_MANIFEST]
    }
  }.freeze

  module_function

  # The pages that have a layout (the AI models page draws its own)
  def configs = PAGES.keys

  # The layout of a page for the settings it has. A setting the table does not know (added later, not classified yet)
  # lands under «Для разработчика»: the safe place for something nobody has decided about.
  def page(config, allowed_keys)
    spec = PAGES.fetch(config.to_s) { { sections: { nil => allowed_keys } } }
    allowed = allowed_keys.to_a
    sections = sections_of(spec, allowed)
    listed = spec.slice(:developer, :read_only, :hidden).values.flatten
    Page.new(
      config: config.to_s, sections: sections,
      developer: (spec.fetch(:developer, []) & allowed) + (allowed - sections.flat_map(&:keys) - listed),
      read_only: spec.fetch(:read_only, []) & allowed, hidden: spec.fetch(:hidden, []) & allowed
    )
  end

  # The settings of a page that it does not draw as a control: the ones that do nothing and the ones shown as text
  def not_editable(config)
    spec = PAGES.fetch(config.to_s, {})
    spec.fetch(:hidden, []) + spec.fetch(:read_only, [])
  end

  def sections_of(spec, allowed)
    spec[:sections].filter_map do |id, keys|
      keys &= allowed
      Section.new(id: id, keys: keys) if keys.any?
    end
  end
end
