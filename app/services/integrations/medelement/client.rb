class Integrations::Medelement::Client
  class ApiError < StandardError
    attr_reader :status

    def initialize(message, status: nil, ambiguous: false)
      super(message)
      @status = status
      @ambiguous = ambiguous
    end

    def ambiguous?
      @ambiguous
    end

    def retryable?
      status.nil? || status == 408 || status == 429 || status >= 500
    end
  end

  BASE_URL = 'https://api3.medelement.com'.freeze

  def initialize(configuration:)
    @request = Integrations::Medelement::Request.new(configuration: configuration)
  end

  def get_patient(patient_code:)
    single_record(request.call(:get, "/doctor/v1/patient/#{patient_code}", operation: 'patient'))
  end

  def search_patients_by_phone(phone_number:, skip: 0)
    phone = Integrations::Medelement::PhoneNumber.new(phone_number)
    response = request.indexed_get(
      '/doctor/v1/patients',
      operation: 'patient search',
      query: phone.query(skip: skip),
      empty_not_found: true
    )

    Array(response).select { |patient| phone.matches_patient?(patient) }
  end

  def search_patients_by_iin(iin:, skip: 0)
    indexed_patient_search([['iin[]', iin.to_s], ['skip', skip]])
  end

  def search_patients_by_codes(patient_codes:, skip: 0)
    pairs = Array(patient_codes).filter_map { |code| ['patient_code[]', code.to_s] if code.present? }
    indexed_patient_search(pairs << ['skip', skip])
  end

  def specialists
    response = request.call(:get, '/v1/timetable/get_specialists', operation: 'specialists')
    response.is_a?(Hash) ? response.values : Array(response)
  end

  def nomenclatures(skip: 0, query: nil)
    params = { skip: skip }
    params[:q] = query if query.present?
    Array(request.call(:get, '/v1/doctor/nomenclatures', operation: 'nomenclatures', query: params))
  end

  def timetable(specialist_code:, starts_on:, ends_on:)
    (starts_on.to_date..ends_on.to_date).each_with_object({}) do |date, result|
      payload = request.call(
        :get,
        '/v1/timetable/get_timetable',
        operation: 'timetable',
        query: URI.encode_www_form([['date', provider_date(date)], ['specialistCode', specialist_code]])
      )
      result.merge!(payload) if payload.is_a?(Hash)
    end
  end

  def get_receptions(company_cabinet_code:, specialist_code:, begin_datetime:, end_datetime:, skip: 0)
    request.receptions(
      company_cabinet_code: company_cabinet_code,
      specialist_code: specialist_code,
      begin_datetime: begin_datetime,
      end_datetime: end_datetime,
      skip: skip
    )
  end

  def get_reception(reception_code:, version: :v2)
    return reception_detail(reception_code, :v1) if version.to_sym == :v1

    detail = reception_detail(reception_code, :v2)
    return detail if valid_reception_detail?(detail, reception_code)

    reception_detail(reception_code, :v1)
  rescue ApiError
    return reception_detail(reception_code, :v1) unless version.to_sym == :v1

    raise
  end

  def search_receptions(params:)
    response = request.call(
      :post,
      '/v2/doctor/reception/search_with_service',
      operation: 'reception search',
      body: form_body(params)
    )
    response.is_a?(Hash) ? Array(response['receptions']) : Array(response)
  end

  def create_patient(params:)
    request.call(:post, '/doctor/v1/patient', operation: 'patient create', body: form_body(params), write: true)
  end

  def update_patient(params:)
    request.call(:put, '/doctor/v1/patient', operation: 'patient update', body: form_body(params), write: true)
  end

  def create_reception(params:)
    request.call(:post, '/v1/doctor/reception', operation: 'reception create', body: form_body(params), write: true)
  end

  def move_reception(params:)
    request.call(
      :post,
      '/v2/doctor/reception/change_reception_date',
      operation: 'reception move',
      body: form_body(params),
      write: true
    )
  end

  def remove_reception(reception_code:)
    request.call(
      :post,
      '/v2/doctor/reception/remove',
      operation: 'reception remove',
      body: form_body(reception_code: reception_code),
      write: true
    )
  end

  private

  attr_reader :request

  def indexed_patient_search(pairs)
    request.indexed_get(
      '/doctor/v1/patients',
      operation: 'patient search',
      query: URI.encode_www_form(pairs),
      empty_not_found: true
    )
  end

  def form_body(params)
    pairs = params.to_h.flat_map do |key, value|
      if value.is_a?(Array)
        value.map { |item| ["#{key}[]", item] }
      else
        [[key, value]]
      end
    end
    URI.encode_www_form(pairs)
  end

  def provider_date(value)
    value.to_date.strftime('%d.%m.%Y')
  end

  def reception_detail(reception_code, version)
    single_record(request.call(:get, "/#{version}/doctor/reception/#{reception_code}", operation: 'reception'))
  end

  def valid_reception_detail?(detail, reception_code)
    detail.is_a?(Hash) && detail['RECEPTION_CODE'].to_s == reception_code.to_s
  end

  def single_record(payload)
    payload.is_a?(Array) ? payload.first : payload
  end
end
