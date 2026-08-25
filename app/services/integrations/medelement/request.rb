class Integrations::Medelement::Request
  EMPTY_RECEPTIONS_MESSAGE = 'Приемы не найдены'.freeze
  REQUEST_TIMEOUT = 20
  TRANSPORT_ERRORS = [
    SocketError,
    Timeout::Error,
    EOFError,
    Errno::ECONNRESET,
    Errno::ECONNREFUSED,
    OpenSSL::SSL::SSLError,
    Integrations::Medelement::RequestRateLimiter::UnavailableError
  ].freeze

  def initialize(
    configuration:,
    sleeper: ->(seconds) { Kernel.sleep(seconds) },
    randomizer: ->(minimum, maximum) { Kernel.rand(minimum..maximum) },
    rate_limiter: nil,
    clock: nil
  )
    @configuration = configuration
    limiter = rate_limiter || Integrations::Medelement::RequestRateLimiter.new(
      integrator_key: configuration.integrator_key,
      interval_ms: configuration.throttle_ms,
      sleeper: sleeper
    )
    @retry_policy = Integrations::Medelement::RequestRetryPolicy.new(
      rate_limiter: limiter,
      transport_errors: TRANSPORT_ERRORS,
      sleeper: sleeper,
      randomizer: randomizer,
      clock: clock
    )
  end

  # Public transport boundary mirrors the provider request options.
  # rubocop:disable Metrics/CyclomaticComplexity, Metrics/ParameterLists
  def call(method, path, operation:, query: nil, body: nil, write: false, empty_not_found: false)
    url = "#{Integrations::Medelement::Client::BASE_URL}#{path}"
    url = "#{url}?#{query}" if query.is_a?(String)
    response = retry_policy.call(operation: operation, write: write) do
      HTTParty.public_send(method, url, request_options(query.is_a?(String) ? nil : query, body))
    end
    parsed_response = response.parsed_response
    return [] if empty_not_found && response.code.to_i == 404 && parsed_response == []
    return validate_provider_scope!(parsed_response) if response.success?

    raise_api_error(operation, response.code.to_i, write: write)
  rescue *TRANSPORT_ERRORS => e
    raise Integrations::Medelement::Client::ApiError.new(
      "Medelement #{operation} transport failed: #{e.class}",
      ambiguous: write
    )
  end

  # rubocop:enable Metrics/CyclomaticComplexity, Metrics/ParameterLists

  # rubocop:disable Metrics/AbcSize
  def indexed_get(path, query:, operation:, empty_not_found: false)
    uri = URI("#{Integrations::Medelement::Client::BASE_URL}#{path}")
    uri.query = query
    request = Net::HTTP::Get.new(uri)
    request.basic_auth(configuration.company_login, configuration.password)
    headers(false).each { |key, value| request[key] = value }
    response = retry_policy.call(operation: operation) do
      perform_indexed_get(uri, request)
    end
    parsed_response = parse_body(response.body)
    return [] if empty_not_found && response.code.to_i == 404 && parsed_response == []
    return validate_provider_scope!(parsed_response) if response.is_a?(Net::HTTPSuccess)

    raise_api_error(operation, response.code.to_i)
  rescue *TRANSPORT_ERRORS => e
    raise Integrations::Medelement::Client::ApiError, "Medelement #{operation} transport failed: #{e.class}"
  end

  # rubocop:enable Metrics/AbcSize

  def receptions(company_cabinet_code:, specialist_code:, begin_datetime:, end_datetime:, skip: 0)
    response = retry_policy.call(operation: 'receptions') do
      HTTParty.post(
        "#{Integrations::Medelement::Client::BASE_URL}/v1/timetable/get_receptions",
        request_options(nil, receptions_body(company_cabinet_code, specialist_code, begin_datetime, end_datetime, skip))
      )
    end
    parsed_response = response.parsed_response
    return [] if empty_receptions_response?(response, parsed_response)
    return scoped_receptions(parsed_response) if response.success?

    raise_api_error('receptions', response.code.to_i)
  rescue *TRANSPORT_ERRORS => e
    raise Integrations::Medelement::Client::ApiError, "Medelement receptions transport failed: #{e.class}"
  end

  private

  attr_reader :configuration, :retry_policy

  def perform_indexed_get(uri, request)
    Net::HTTP.start(
      uri.host,
      uri.port,
      use_ssl: true,
      open_timeout: REQUEST_TIMEOUT,
      read_timeout: REQUEST_TIMEOUT
    ) { |http| http.request(request) }
  end

  def receptions_body(company_cabinet_code, specialist_code, begin_datetime, end_datetime, skip)
    {
      companyCabinetCode: company_cabinet_code,
      specialistCode: specialist_code,
      beginDatetime: begin_datetime,
      endDatetime: end_datetime,
      skip: skip
    }
  end

  def request_options(query, body)
    options = {
      basic_auth: {
        username: configuration.company_login,
        password: configuration.password
      },
      headers: headers(body.present?),
      timeout: REQUEST_TIMEOUT
    }
    options[:query] = query if query.present?
    options[:body] = body if body.present?
    options
  end

  def validate_provider_scope!(payload)
    Integrations::Medelement::ProviderScope.validate!(
      payload,
      organization_id: configuration.organization_id
    )
  end

  def scoped_receptions(payload)
    validated = validate_provider_scope!(payload)
    return Array(validated['receptions']) if validated.is_a?(Hash)

    Array(validated)
  end

  def validate_configuration!
    validate_provider_scope!({})
  end

  def headers(form_encoded)
    validate_configuration!
    values = {
      'Accept' => 'application/json',
      'X-Integrator-Key' => configuration.integrator_key
    }
    values['Content-Type'] = 'application/x-www-form-urlencoded' if form_encoded
    values
  end

  def raise_api_error(operation, status, write: false)
    raise Integrations::Medelement::Client::ApiError.new(
      "Medelement #{operation} request failed",
      status: status,
      ambiguous: write && (status == 408 || status == 429 || status >= 500)
    )
  end

  def empty_receptions_response?(response, parsed_response)
    return false unless response.code.to_i == 404

    messages = [
      response.body.to_s,
      parsed_response.is_a?(Hash) ? parsed_response['message'] : nil,
      parsed_response
    ]
    messages.any? { |message| message.to_s.include?(EMPTY_RECEPTIONS_MESSAGE) }
  end

  def parse_body(body)
    JSON.parse(body)
  rescue JSON::ParserError
    body
  end
end
