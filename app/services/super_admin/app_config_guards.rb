# frozen_string_literal: true

# The switches of the settings pages that change how the platform works for ALL accounts at once. Each one says in one
# line what it does, and changing one asks first (the question is built in the browser from `confirm_on` /
# `confirm_off` of each switch that moved, the same way the «Служебные» switches of an account card do).
#
# The texts live in config/locales/super_admin_config_pages.ru.yml under `super_admin.app_config.guards.<NAME>`; the
# questions name how many connected channels the change reaches, so the owner sees what he is about to touch.
#
#   guard = SuperAdmin::AppConfigGuards.for('ENABLE_MESSENGER_CHANNEL_HUMAN_AGENT')
#   guard.effect      # => "Включено — на ответ клиенту в Messenger даётся 7 дней вместо 24 часов. ..."
#   guard.confirm_on  # => "Включить тег «человек-оператор» для всех страниц Messenger (подключено: 3)? ..."
module SuperAdmin::AppConfigGuards
  SCOPE = 'super_admin.app_config.guards'
  Guard = Struct.new(:key, :effect, :confirm_on, :confirm_off, keyword_init: true)

  # The setting => how many connected channels of the kind it reaches (a setting that is not about channels has none)
  CHANNEL_COUNTS = {
    'ENABLE_MESSENGER_CHANNEL_HUMAN_AGENT' => -> { Channel::FacebookPage.count },
    'ENABLE_INSTAGRAM_CHANNEL_HUMAN_AGENT' => -> { Channel::Instagram.count },
    'WHATSAPP_PROACTIVE_REAUTHORIZATION_ENABLED' => -> { Channel::Whatsapp.where(provider: 'whatsapp_cloud').count },
    'WHATSAPP_REQUIRE_NON_EXPIRING_SYSTEM_USER_TOKEN' => -> { Channel::Whatsapp.where(provider: 'whatsapp_cloud').count }
  }.freeze
  KEYS = (%w[ENABLE_ACCOUNT_SIGNUP ENABLE_GOOGLE_OAUTH_LOGIN] + CHANNEL_COUNTS.keys).freeze

  module_function

  def guarded?(key)
    KEYS.include?(key.to_s)
  end

  # nil for a setting that is an ordinary switch
  def for(key)
    key = key.to_s
    return unless guarded?(key)

    options = text_options(key)
    Guard.new(
      key: key,
      effect: I18n.t("#{SCOPE}.#{key}.effect", **options),
      confirm_on: I18n.t("#{SCOPE}.#{key}.confirm_on", **options),
      confirm_off: I18n.t("#{SCOPE}.#{key}.confirm_off", **options)
    )
  end

  # The numbers the texts name: connected channels of the kind, and for the signup the days of the trial and whether the
  # bot protection is set
  def text_options(key)
    options = key == 'ENABLE_ACCOUNT_SIGNUP' ? { trial_days: Accounts::Plans.trial_days, protection: protection_text } : {}
    count = CHANNEL_COUNTS[key]&.call
    options[:count] = count unless count.nil?
    options
  end

  # Bot protection of the signup form (hCaptcha): both keys are needed, the site key to draw the check and the server
  # key to verify it. With only one of them the form either has no check or cannot be sent.
  def protection_configured?
    %w[HCAPTCHA_SITE_KEY HCAPTCHA_SERVER_KEY].all? { |name| InstallationConfig.find_by(name: name)&.value.present? }
  end

  def protection_text
    I18n.t("#{SCOPE}.protection.#{protection_configured? ? 'on' : 'off'}")
  end
end
