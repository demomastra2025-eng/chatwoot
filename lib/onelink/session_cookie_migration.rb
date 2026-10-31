# frozen_string_literal: true

# Re-encrypts the session for its new cookie purpose. During a rolling release
# the old cookie remains authoritative and is mirrored for old web replicas.
class Onelink::SessionCookieMigration
  LEGACY_KEY = '_chatwoot_session'
  CURRENT_KEY = '_onelink_session'

  def initialize(app, cookie_options:, bridge: true, primary_key: CURRENT_KEY)
    raise ArgumentError, 'Retire legacy sessions only with the canonical primary' if !bridge && primary_key != CURRENT_KEY

    @app = app
    @legacy_key = LEGACY_KEY
    @current_key = CURRENT_KEY
    @cookie_options = cookie_options
    @bridge = bridge
    @primary_key = primary_key
  end

  def call(env)
    request = ActionDispatch::Request.new(env)
    cookies = request.cookie_jar
    alias_received = cookies.key?(alias_key)
    import_legacy_session(cookies)
    response = @app.call(env)
    if request.session.options[:drop]
      [legacy_key, current_key].each { |key| cookies.delete(key, cookie_options) }
    else
      synchronize_legacy_session(cookies, alias_received: alias_received)
    end
    response
  end

  private

  attr_reader :legacy_key, :current_key, :cookie_options, :bridge, :primary_key

  def alias_key
    primary_key == current_key ? legacy_key : current_key
  end

  def import_legacy_session(cookies)
    encrypted = cookies.signed_or_encrypted
    primary = encrypted[primary_key]
    return if primary.is_a?(Hash) && (primary_key == legacy_key || !bridge)

    alternate = encrypted[alias_key]
    encrypted[primary_key] = cookie_options.merge(value: alternate) if alternate.is_a?(Hash)
  end

  def synchronize_legacy_session(cookies, alias_received:)
    primary = cookies.signed_or_encrypted[primary_key]
    mirror = primary_key == current_key ? bridge : alias_received
    if mirror && primary.is_a?(Hash)
      cookies.signed_or_encrypted[alias_key] = cookie_options.merge(value: primary)
    elsif cookies.key?(alias_key)
      # A dropped/logged-out session must never be resurrected by its alias.
      cookies.delete(alias_key, cookie_options)
    end
  end
end
