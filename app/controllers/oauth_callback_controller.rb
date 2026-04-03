class OauthCallbackController < ApplicationController
  OAUTH_CALLBACK_ERROR = 'oauth_callback_failed'.freeze

  def show
    @response = oauth_client.auth_code.get_token(
      oauth_code,
      redirect_uri: "#{base_url}/#{provider_name}/callback"
    )

    handle_response
  rescue StandardError => e
    ChatwootExceptionTracker.new(e).capture_exception
    redirect_to oauth_error_redirect_url, allow_other_host: true
  end

  private

  def handle_response
    inbox, already_exists = find_or_create_inbox

    if already_exists
      redirect_to app_email_inbox_settings_url(account_id: account.id, inbox_id: inbox.id), allow_other_host: true
    else
      redirect_to app_email_inbox_agents_url(account_id: account.id, inbox_id: inbox.id), allow_other_host: true
    end
  end

  def find_or_create_inbox
    channel_email = find_channel_by_email
    # we need this value to know where to redirect on sucessful processing of the callback
    channel_exists = channel_email.present?

    if channel_exists
      update_channel(channel_email)
    else
      ActiveRecord::Base.transaction do
        channel_email = create_channel_with_inbox
        update_channel(channel_email)
      end
    end

    # reauthorize channel, this code path only triggers when microsoft auth is successful
    # reauthorized will also update cache keys for the associated inbox
    channel_email.reauthorized!

    [channel_email.inbox, channel_exists]
  end

  def find_channel_by_email
    Channel::Email.find_by(email: users_data['email'], account: account)
  end

  def update_channel(channel_email)
    existing_provider_config = channel_email.provider_config.to_h
    refresh_token = parsed_body['refresh_token'].presence || existing_provider_config['refresh_token'].presence
    raise BaseRefreshOauthTokenService::MissingRefreshTokenError, 'A refresh_token is not available' if refresh_token.blank?

    channel_email.update!({
                            imap_login: users_data['email'], imap_address: imap_address,
                            imap_port: '993', imap_enabled: true,
                            provider: provider_name,
                            provider_config: existing_provider_config.merge(
                              'access_token' => parsed_body['access_token'],
                              'refresh_token' => refresh_token,
                              'expires_on' => resolved_expires_on.to_s
                            )
                          })
  end

  def provider_name
    raise NotImplementedError
  end

  def oauth_client
    raise NotImplementedError
  end

  def create_channel_with_inbox
    ActiveRecord::Base.transaction do
      channel_email = Channel::Email.create!(email: users_data['email'], account: account)

      account.inboxes.create!(
        account: account,
        channel: channel_email,
        name: users_data['name'] || fallback_name
      )
      channel_email
    end
  end

  def users_data
    decoded_token = JWT.decode parsed_body[:id_token], nil, false
    decoded_token[0]
  end

  def account_from_signed_id
    raise ActionController::BadRequest, 'Missing state variable' if params[:state].blank?

    account = GlobalID::Locator.locate_signed(params[:state])
    raise 'Invalid or expired state' if account.nil?

    account
  end

  def account
    @account ||= account_from_signed_id
  end

  # Fallback name, for when name field is missing from users_data
  def fallback_name
    users_data['email'].split('@').first.parameterize.titleize
  end

  def oauth_code
    params[:code]
  end

  def base_url
    ENV.fetch('FRONTEND_URL', 'http://localhost:3000')
  end

  def oauth_error_redirect_url
    redirect_account = GlobalID::Locator.locate_signed(params[:state]) if params[:state].present?
    return '/' unless redirect_account

    "#{base_url}/app/accounts/#{redirect_account.id}/settings/inboxes/new/#{provider_name}?error=#{OAUTH_CALLBACK_ERROR}"
  rescue StandardError
    '/'
  end

  def parsed_body
    @parsed_body ||= @response.response.parsed
  end

  def resolved_expires_on
    expires_at_value = parsed_body['expires_at']
    parsed_expires_at = parse_oauth_expiry_time(expires_at_value)
    return parsed_expires_at if parsed_expires_at.present?

    expires_in_value = parsed_body['expires_in']
    expires_in_seconds = parse_oauth_expiry_seconds(expires_in_value)
    return Time.current.utc + expires_in_seconds.seconds if expires_in_seconds.present?

    Time.current.utc + 1.hour
  end

  def parse_oauth_expiry_time(value)
    return if value.blank?
    return Time.at(value).utc if value.is_a?(Numeric)

    integer_value = Integer(value)
    Time.at(integer_value).utc
  rescue ArgumentError, TypeError
    Time.zone.parse(value.to_s)&.utc
  end

  def parse_oauth_expiry_seconds(value)
    return if value.blank?

    Integer(value)
  rescue ArgumentError, TypeError
    nil
  end
end
