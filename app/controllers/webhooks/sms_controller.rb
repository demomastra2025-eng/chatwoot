class Webhooks::SmsController < ActionController::API
  before_action :set_channel
  before_action :authenticate_webhook!

  def process_payload
    events = extract_event_payloads
    return head :unprocessable_entity if events == :invalid
    return head :ok if events.empty?
    return head :unauthorized if events.any? { |event| cross_channel_payload?(event) }

    events.each do |event|
      Webhooks::SmsEventsJob.perform_later(event.merge('to' => @channel.phone_number))
    end
    head :ok
  end

  private

  def set_channel
    phone = params[:phone_number].to_s.strip
    return if phone.blank?

    candidates = [phone, "+#{phone.delete_prefix('+')}"].uniq
    @channel = Channel::Sms.find_by(phone_number: candidates)
  end

  def authenticate_webhook!
    return head :unauthorized if @channel.blank?
    return if authenticated_via_basic_auth? || authenticated_via_secret?

    head :unauthorized
  end

  def authenticated_via_basic_auth?
    return false unless ActionController::HttpAuthentication::Basic.has_basic_credentials?(request)

    provided_user, provided_pass = ActionController::HttpAuthentication::Basic.user_name_and_password(request)
    expected_user, expected_pass = expected_basic_credentials
    user_ok = secure_match?(provided_user, expected_user)
    pass_ok = secure_match?(provided_pass, expected_pass)
    user_ok && pass_ok
  end

  def expected_basic_credentials
    cfg = provider_config
    if cfg['webhook_username'].present? || cfg['webhook_password'].present?
      [cfg['webhook_username'].to_s, cfg['webhook_password'].to_s]
    else
      [cfg['api_key'].to_s, cfg['api_secret'].to_s]
    end
  end

  def authenticated_via_secret?
    provided_secret = request.headers['X-Sms-Webhook-Secret'].to_s.strip.presence || bearer_token
    secure_match?(provided_secret, expected_webhook_secret)
  end

  def expected_webhook_secret
    channel_secret = provider_config['webhook_secret'].to_s.strip.presence
    return channel_secret if channel_secret.present?
    return nil if channel_basic_credentials_configured?

    ENV.fetch('SMS_WEBHOOK_SECRET', '').to_s.strip.presence
  end

  def channel_basic_credentials_configured?
    expected_basic_credentials.any?(&:present?)
  end

  def bearer_token
    request.authorization.to_s[/\ABearer\s+(.+)\z/i, 1]&.strip.presence
  end

  def provider_config
    @channel&.provider_config.is_a?(Hash) ? @channel.provider_config : {}
  end

  def extract_event_payloads
    return [] unless params.key?('_json') && !params['_json'].nil?
    return :invalid unless params['_json'].is_a?(Array)

    raw_items = params['_json']
    normalized = raw_items.map { |item| item.respond_to?(:to_unsafe_hash) ? item.to_unsafe_hash : item }
    return :invalid unless normalized.all?(Hash)

    normalized
  end

  def cross_channel_payload?(payload)
    return true if mismatched_owner?(payload.dig('message', 'owner'))
    return false unless inbound_event?(payload) && payload['to'].present?

    inbound_targets(payload['to']).any? { |target| !same_phone?(target, @channel.phone_number) }
  end

  def mismatched_owner?(owner)
    owner.present? && !same_phone?(owner, @channel.phone_number)
  end

  def inbound_targets(raw_to)
    Array(raw_to).map(&:to_s).reject(&:blank?)
  end

  def same_phone?(left, right)
    normalize_phone(left) == normalize_phone(right)
  end

  def inbound_event?(payload)
    payload['type'].to_s == 'message-received' || payload.dig('message', 'direction').to_s == 'in'
  end

  def normalize_phone(value)
    "+#{value.to_s.strip.delete_prefix('+')}"
  end

  def secure_match?(provided, expected)
    provided_str = provided.to_s
    expected_str = expected.to_s
    return false if provided_str.blank? || expected_str.blank?

    provided_digest = OpenSSL::Digest::SHA256.digest(provided_str)
    expected_digest = OpenSSL::Digest::SHA256.digest(expected_str)
    ActiveSupport::SecurityUtils.fixed_length_secure_compare(provided_digest, expected_digest)
  end
end
