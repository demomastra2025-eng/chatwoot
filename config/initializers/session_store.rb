# Be sure to restart your server when you modify this file.
# Sessions are used only for the super_admin dashboard (flash/CSRF), not for API auth.

secure_cookies = ActiveModel::Type::Boolean.new.cast(ENV.fetch('FORCE_SSL', false))
cookie_options = { same_site: :lax, secure: secure_cookies, httponly: true, path: '/' }
# First deploy cookie-aware code everywhere without issuing the new name. Only
# then switch the primary key; old-name replicas can now mirror/reset both keys.
session_key = ENV.fetch('ONELINK_SESSION_COOKIE_NAME', '_chatwoot_session')
raise 'Unsupported OneLink session cookie name' unless %w[_chatwoot_session _onelink_session].include?(session_key)

Rails.application.config.session_store :cookie_store,
                                       **cookie_options,
                                       key: session_key

require Rails.root.join('lib/onelink/session_cookie_migration')
bridge = %w[true 1 yes on].include?(ENV.fetch('ONELINK_LEGACY_SESSION_COOKIE_BRIDGE', 'true').to_s.strip.downcase)
Rails.application.config.middleware.insert_before(
  ActionDispatch::Session::CookieStore, Onelink::SessionCookieMigration,
  primary_key: session_key,
  cookie_options: cookie_options, bridge: bridge
)
