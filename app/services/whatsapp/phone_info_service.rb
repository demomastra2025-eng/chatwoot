class Whatsapp::PhoneInfoService
  CALLING_CAPABILITY_VALUES = %w[CALLING CALLS VOICE VOICE_CALLING WHATSAPP_CALLING calling calls voice voice_calling whatsapp_calling].freeze
  PHONE_NUMBER_FIELDS = %w[
    id display_phone_number verified_name code_verification_status
    platform_type is_on_biz_app capabilities calling_capabilities calls calling
  ].freeze

  def initialize(waba_id, phone_number_id, access_token, coexistence: false, allow_unambiguous_selection: false)
    @waba_id = waba_id
    @phone_number_id = phone_number_id
    @access_token = access_token
    @coexistence = coexistence
    @allow_unambiguous_selection = allow_unambiguous_selection || coexistence
    @api_client = Whatsapp::FacebookApiClient.new(access_token)
  end

  def perform
    validate_parameters!
    fetch_and_process_phone_info
  end

  private

  def validate_parameters!
    raise ArgumentError, 'WABA ID is required' if @waba_id.blank?
    raise ArgumentError, 'Phone number ID is required' if @phone_number_id.blank? && !@allow_unambiguous_selection
    raise ArgumentError, 'Access token is required' if @access_token.blank?
  end

  def fetch_and_process_phone_info
    phone_data = resolve_phone_data

    raise missing_phone_number_message if phone_data.nil?

    build_phone_info(phone_data)
  end

  def resolve_phone_data
    matches = []
    after = nil

    loop do
      response = fetch_phone_numbers_page(after)
      matches.concat(find_phone_data(response['data']))
      after = next_phone_page_cursor(response)
      break if matches.present? && @phone_number_id.present?
      break if after.blank?
    end

    return matches.first if matches.one?
    raise 'Multiple eligible phone numbers matched this WABA; reconnect the intended number separately' if matches.many?

    nil
  end

  def fetch_phone_numbers_page(after)
    if @coexistence
      @api_client.fetch_phone_numbers(@waba_id, after: after, fields: PHONE_NUMBER_FIELDS)
    elsif after.present?
      @api_client.fetch_phone_numbers(@waba_id, after: after)
    else
      @api_client.fetch_phone_numbers(@waba_id)
    end
  end

  def next_phone_page_cursor(response)
    response.dig('paging', 'cursors', 'after') if response.dig('paging', 'next').present?
  end

  def find_phone_data(phone_numbers)
    return [] if phone_numbers.blank?

    return phone_numbers.select { |phone| phone['id'].to_s == @phone_number_id.to_s } if @phone_number_id.present?
    return phone_numbers unless @coexistence

    phone_numbers.select do |phone|
      ActiveModel::Type::Boolean.new.cast(phone['is_on_biz_app']) && phone['platform_type'].to_s == 'CLOUD_API'
    end
  end

  def missing_phone_number_message
    return "No phone number is available for WABA #{@waba_id}" if @phone_number_id.blank?

    "Phone number #{@phone_number_id} is not available for WABA #{@waba_id}"
  end

  def build_phone_info(phone_data)
    display_phone_number = sanitize_phone_number(phone_data['display_phone_number'])

    info = {
      phone_number_id: phone_data['id'],
      phone_number: "+#{display_phone_number}",
      verified: phone_data['code_verification_status'] == 'VERIFIED',
      business_name: phone_data['verified_name'] || phone_data['display_phone_number'],
      calling_capable: calling_capable?(phone_data),
      calling_capabilities: calling_capabilities(phone_data)
    }
    info[:is_on_biz_app] = ActiveModel::Type::Boolean.new.cast(phone_data['is_on_biz_app']) if phone_data.key?('is_on_biz_app')
    info[:platform_type] = phone_data['platform_type'] if phone_data.key?('platform_type')
    info
  end

  def sanitize_phone_number(phone_number)
    return phone_number if phone_number.blank?

    phone_number.gsub(/[\s\-\(\)\.\+]/, '').strip
  end

  def calling_capable?(phone_data)
    calling_capabilities(phone_data).intersect?(CALLING_CAPABILITY_VALUES) ||
      ActiveModel::Type::Boolean.new.cast(phone_data['calling_capable']) ||
      ActiveModel::Type::Boolean.new.cast(phone_data['calling_enabled']) ||
      false
  end

  def calling_capabilities(phone_data)
    Array(phone_data['capabilities']) +
      Array(phone_data['calling_capabilities']) +
      Array(phone_data.dig('calls', 'capabilities')) +
      Array(phone_data.dig('calling', 'capabilities'))
  end
end
