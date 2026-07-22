class Whatsapp::TokenValidationService
  NON_EXPIRING_SYSTEM_USER_TOKEN_ERROR = 'Meta Embedded Signup must issue a non-expiring SYSTEM_USER token. ' \
                                           'Set token expiration to Never in the active Facebook Login for Business configuration and retry.'.freeze

  def initialize(access_token, waba_id, phone_number_id: nil, require_non_expiring_system_user: false)
    @access_token = access_token
    @waba_id = waba_id
    @phone_number_id = phone_number_id
    @require_non_expiring_system_user = require_non_expiring_system_user
  end

  def perform
    token_health = inspect_token
    raise validation_error_message(token_health) if reauthorization_required?(token_health)
    raise NON_EXPIRING_SYSTEM_USER_TOKEN_ERROR unless acceptable_token_lifetime?(token_health)

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

  def acceptable_token_lifetime?(token_health)
    return true unless @require_non_expiring_system_user

    token_health['token_type'] == 'SYSTEM_USER' && token_health['never_expires'] == true
  end

  def validation_error_message(token_health)
    case token_health['status']
    when Whatsapp::TokenInspectionService::PERMISSION_MISSING_STATUS
      "Token is missing required WhatsApp permissions: #{Array(token_health['missing_permissions']).join(', ')}"
    when Whatsapp::TokenInspectionService::APP_ID_MISMATCH_STATUS
      "Token belongs to Meta App #{token_health['app_id']}, expected #{token_health['expected_app_id']}"
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
