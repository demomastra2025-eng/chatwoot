class Whatsapp::TokenValidationService
  def initialize(access_token, waba_id, phone_number_id: nil)
    @access_token = access_token
    @waba_id = waba_id
    @phone_number_id = phone_number_id
  end

  def perform
    token_health = inspect_token
    raise validation_error_message(token_health) if reauthorization_required?(token_health)

    token_health
  end

  private

  def inspect_token
    Whatsapp::TokenInspectionService.new(
      access_token: @access_token,
      waba_id: @waba_id,
      phone_number_id: @phone_number_id
    ).perform
  end

  def reauthorization_required?(token_health)
    Whatsapp::TokenInspectionService::REAUTHORIZATION_STATUSES.include?(token_health['status'])
  end

  def validation_error_message(token_health)
    case token_health['status']
    when Whatsapp::TokenInspectionService::PERMISSION_MISSING_STATUS
      "Token is missing required WhatsApp permissions: #{Array(token_health['missing_permissions']).join(', ')}"
    when Whatsapp::TokenInspectionService::PHONE_NUMBER_MISMATCH_STATUS
      available_phone_numbers = Array(token_health['available_phone_number_ids']).join(', ')
      "Token does not have access to phone number #{@phone_number_id}. Available phone numbers: #{available_phone_numbers}"
    when Whatsapp::TokenInspectionService::WABA_ACCESS_MISSING_STATUS
      "Token does not have access to WABA #{@waba_id}: #{token_health.dig('error', 'message')}"
    else
      token_health.dig('error', 'message').presence || 'WhatsApp token is invalid'
    end
  end
end
