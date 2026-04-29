class Integrations::Macrocrm::Client
  class ApiError < StandardError
    attr_reader :endpoint, :status, :retryable

    def initialize(message, endpoint: nil, status: nil, retryable: false)
      super(message)
      @endpoint = endpoint
      @status = status
      @retryable = retryable
    end
  end

  class TransientError < ApiError; end
  class PermanentError < ApiError; end
  class UnknownOutcomeError < PermanentError; end

  BASE_URL = 'https://api.macroserver.kz/v2'.freeze
  REQUEST_TIMEOUT = 20
  MAX_RETRYABLE_ATTEMPTS = 2
  RETRY_DELAY_SECONDS = 0.25
  TRANSIENT_STATUS_CODES = [408, 429, 500, 502, 503, 504].freeze
  RETRYABLE_POST_ENDPOINTS = [
    '/contacts/find',
    '/estateBuy/find',
    '/estateBuy/list'
  ].freeze

  def initialize(hook:)
    @hook = hook
  end

  def find_contact(phone:)
    post('/contacts/find', { phone: phone })
  end

  def find_estate_buy(contact_id:)
    post('/estateBuy/find', { contacts_id: contact_id })
  end

  def list_estate_buy(ids:, statuses: [])
    payload = { ids: ids }
    payload[:statuses] = statuses if statuses.present?

    post('/estateBuy/list', payload)
  end

  def create_estate_buy(name:, phone:, message:, manager_id: nil)
    payload = {
      name: name,
      phone: phone,
      action: 'buy',
      message: message,
      utm: {
        channel_medium: 'WhatsApp (One-Link)',
        utm_source: 'whatsapp',
        utm_medium: 'messenger',
        utm_campaign: 'one-link'
      }
    }
    payload[:manager_id] = manager_id if manager_id.present?

    post('/estateBuy/create', payload)
  end

  def add_note(estate_id:, note:)
    post('/estateBuy/addNote', {
           id: estate_id,
           note: note
         })
  end

  def company_users
    get('/company/getUsers')
  end

  private

  attr_reader :hook

  def post(endpoint, payload)
    request(
      method: :post,
      endpoint: endpoint,
      options: {
        body: payload.to_json,
        headers: headers
      },
      retryable: RETRYABLE_POST_ENDPOINTS.include?(endpoint)
    )
  end

  def get(endpoint)
    request(
      method: :get,
      endpoint: endpoint,
      options: {
        headers: headers.except('Content-Type')
      },
      retryable: true
    )
  end

  def request(method:, endpoint:, options:, retryable:)
    attempts = 0

    begin
      attempts += 1
      response = perform_request(method, endpoint, options)

      parsed_response = response.parsed_response
      return parsed_response if response.success?

      handle_unsuccessful_response(endpoint, response, parsed_response, retryable)
    rescue TransientError => e
      raise e if attempts >= max_attempts(retryable)

      wait_before_retry(attempts)
      retry
    rescue SocketError, Timeout::Error => e
      error = transport_error(endpoint, e, retryable)
      raise error if attempts >= max_attempts(error.retryable)

      wait_before_retry(attempts)
      retry
    end
  end

  def perform_request(method, endpoint, options)
    HTTParty.public_send(
      method,
      "#{BASE_URL}#{endpoint}",
      options.merge(timeout: REQUEST_TIMEOUT)
    )
  end

  def handle_unsuccessful_response(endpoint, response, _parsed_response, retryable)
    status = response.code.to_i
    message = "MacroCRM request failed for #{endpoint}: HTTP #{status}"

    if transient_status?(status)
      raise TransientError.new(message, endpoint: endpoint, status: status, retryable: true) if retryable

      raise UnknownOutcomeError.new(
        "#{message}; not retrying non-idempotent MacroCRM write automatically",
        endpoint: endpoint,
        status: status,
        retryable: false
      )
    end

    raise PermanentError.new(message, endpoint: endpoint, status: status, retryable: false)
  end

  def transport_error(endpoint, error, retryable)
    message = "MacroCRM request failed for #{endpoint}: #{error.message}"
    return TransientError.new(message, endpoint: endpoint, retryable: true) if retryable

    UnknownOutcomeError.new(
      "#{message}; not retrying non-idempotent MacroCRM write automatically",
      endpoint: endpoint,
      retryable: false
    )
  end

  def transient_status?(status)
    TRANSIENT_STATUS_CODES.include?(status)
  end

  def max_attempts(retryable)
    retryable ? MAX_RETRYABLE_ATTEMPTS : 1
  end

  def retry_delay(attempt)
    RETRY_DELAY_SECONDS * attempt
  end

  def wait_before_retry(attempt)
    sleep retry_delay(attempt)
  end

  def headers
    {
      'Authorization' => "Bearer #{hook.access_token}",
      'AppId' => hook.settings['app_id'],
      'Content-Type' => 'application/json'
    }
  end
end
