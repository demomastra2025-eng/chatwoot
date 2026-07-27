class Integrations::Medelement::Client
  class ApiError < StandardError
    attr_reader :status

    def initialize(message, status: nil)
      super(message)
      @status = status
    end
  end

  BASE_URL = 'https://api3.medelement.com'.freeze
  EMPTY_RECEPTIONS_MESSAGE = 'Приемы не найдены'.freeze
  REQUEST_TIMEOUT = 20

  def initialize(configuration:)
    @configuration = configuration
  end

  def get_patient(patient_code:)
    get("/doctor/v1/patient/#{patient_code}")
  end

  def get_receptions(company_cabinet_code:, specialist_code:, begin_datetime:, end_datetime:)
    response = HTTParty.post(
      "#{BASE_URL}/v1/timetable/get_receptions",
      basic_auth: basic_auth,
      body: {
        companyCabinetCode: company_cabinet_code,
        specialistCode: specialist_code,
        beginDatetime: begin_datetime,
        endDatetime: end_datetime
      },
      headers: form_headers,
      timeout: REQUEST_TIMEOUT
    )

    parsed_response = response.parsed_response
    return [] if empty_receptions_response?(response, parsed_response)

    return Array(parsed_response['receptions']) if response.success?

    raise ApiError.new('Medelement receptions request failed', status: response.code.to_i)
  rescue SocketError, Timeout::Error, EOFError, Errno::ECONNRESET, Errno::ECONNREFUSED,
         OpenSSL::SSL::SSLError => e
    raise ApiError, "Medelement receptions transport failed: #{e.class}"
  end

  def specialists
    response = get('/v1/timetable/get_specialists')
    return response.values if response.is_a?(Hash)

    Array(response)
  end

  private

  attr_reader :configuration

  def basic_auth
    {
      username: configuration.company_login,
      password: configuration.password
    }
  end

  def form_headers
    headers.merge('Content-Type' => 'application/x-www-form-urlencoded')
  end

  def get(path)
    response = HTTParty.get(
      "#{BASE_URL}#{path}",
      basic_auth: basic_auth,
      headers: headers,
      timeout: REQUEST_TIMEOUT
    )

    parsed_response = response.parsed_response
    return parsed_response if response.success?

    raise ApiError.new("Medelement request failed for #{path}", status: response.code.to_i)
  rescue SocketError, Timeout::Error, EOFError, Errno::ECONNRESET, Errno::ECONNREFUSED,
         OpenSSL::SSL::SSLError => e
    raise ApiError, "Medelement transport failed for #{path}: #{e.class}"
  end

  def headers
    {
      'Accept' => 'application/json',
      'X-Integrator-Key' => configuration.integrator_key
    }
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
end
