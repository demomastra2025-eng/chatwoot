class Webhooks::Trigger
  SUPPORTED_ERROR_HANDLE_EVENTS = %w[message_created message_updated].freeze

  RETRYABLE_API_INBOX_STATUSES = [408, 425, 429].freeze

  class RetryableError < StandardError
    attr_reader :status

    def initialize(status:, message:)
      @status = status
      super(message)
    end
  end

  def initialize(url, payload, webhook_type, secret: nil, delivery_id: nil)
    @url = url
    @payload = payload
    @webhook_type = webhook_type
    @secret = secret
    @delivery_id = delivery_id
  end

  def self.execute(url, payload, webhook_type, secret: nil, delivery_id: nil)
    new(url, payload, webhook_type, secret: secret, delivery_id: delivery_id).execute
  end

  def execute
    perform_request
  rescue StandardError => e
    raise RetryableError.new(status: http_status(e), message: e.message) if retryable_webhook_error?(e)

    handle_failure(e)
  end

  def handle_failure(error)
    handle_error(error)
    Rails.logger.warn "Exception: Invalid webhook URL #{@url} : #{error.message}"
  end

  private

  def perform_request
    body = @payload.to_json
    SafeFetch.fetch(@url, **safe_fetch_options(body)) { |_response| nil }
  end

  def safe_fetch_options(body)
    options = {
      method: :post,
      body: body,
      headers: request_headers(body),
      open_timeout: webhook_timeout,
      read_timeout: webhook_timeout,
      validate_content_type: false
    }

    allowed_hosts = api_inbox_private_network_allowed_hosts
    options[:private_network_allowed_hosts] = allowed_hosts if allowed_hosts.present?

    options
  end

  def request_headers(body)
    headers = { 'Content-Type' => 'application/json', 'Accept' => 'application/json' }
    headers['X-Chatwoot-Delivery'] = @delivery_id if @delivery_id.present?
    if @secret.present?
      ts = Time.now.to_i.to_s
      headers['X-Chatwoot-Timestamp'] = ts
      headers['X-Chatwoot-Signature'] = "sha256=#{OpenSSL::HMAC.hexdigest('SHA256', @secret, "#{ts}.#{body}")}"
    end
    headers
  end

  def handle_error(error)
    return unless SUPPORTED_ERROR_HANDLE_EVENTS.include?(@payload[:event])
    return unless message

    update_message_status(error) if @webhook_type == :api_inbox_webhook
  end

  def update_message_status(error)
    return if message.failed?

    Messages::StatusUpdateService.new(message, 'failed', error.message).perform
  end

  def message
    return if message_id.blank?

    if defined?(@message)
      @message
    else
      @message = Message.find_by(id: message_id)
    end
  end

  def message_id
    @payload[:id]
  end

  def webhook_timeout
    raw_timeout = GlobalConfig.get_value('WEBHOOK_TIMEOUT')
    timeout = raw_timeout.presence&.to_i

    timeout&.positive? ? timeout : 5
  end

  def api_inbox_private_network_allowed_hosts
    return [] unless @webhook_type == :api_inbox_webhook

    ENV.fetch('API_INBOX_WEBHOOK_PRIVATE_NETWORK_ALLOWED_HOSTS', '')
       .split(',')
       .map { |host| host.strip.downcase }
       .compact_blank
       .uniq
  end


  def retryable_api_inbox_error?(error)
    return false unless @webhook_type == :api_inbox_webhook
    return true if error.is_a?(SafeFetch::FetchError)

    status = http_status(error)
    status.present? && (RETRYABLE_API_INBOX_STATUSES.include?(status) || status >= 500)
  end

  def retryable_webhook_error?(error)
    retryable_api_inbox_error?(error)
  end

  def http_status(error)
    return unless error.is_a?(SafeFetch::HttpError)

    error.message.to_s[/\A(\d{3})\b/, 1]&.to_i
  end
end
