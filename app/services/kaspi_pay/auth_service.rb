class KaspiPay::AuthService
  DEFAULT_SETTINGS = {
    'default_payment_type' => 'qr',
    'latitude' => 43.238949,
    'longitude' => 76.889709
  }.freeze

  def initialize(account:, client: KaspiPay::Client.new)
    @account = account
    @client = client
  end

  def init
    body = client.init
    {
      process_id: body['processId'] || body[:process_id],
      view: body['view']
    }.compact
  end

  def send_phone(process_id:, phone_number:)
    body = client.send_phone(process_id: process_id, phone_number: normalize_cashier_phone(phone_number))
    {
      process_id: body['processId'] || process_id,
      view: body['view'],
      description: body['desc'],
      error: body['error'],
      success: body['success']
    }.compact
  end

  def verify_otp(process_id:, otp:, phone_number: nil)
    normalized_phone = normalize_cashier_phone(phone_number)
    normalize_session(client.verify_otp(process_id: process_id, otp: otp, phone_number: normalized_phone), normalized_phone)
  end

  def connect!(session:, settings: {})
    hook = account.hooks.find_or_initialize_by(app_id: 'kaspi_pay')
    hook.settings = DEFAULT_SETTINGS.merge(settings.to_h.deep_stringify_keys.compact_blank)
    hook.status = 'enabled'
    hook.access_token = session.to_json
    hook.save!
    hook
  end

  def refresh!(hook:)
    body = client.refresh(hook: hook)
    unless body['success']
      code = provider_failure_response?(body) ? 'ADAPTER_REQUEST_FAILED' : 'SESSION_REFRESH_FAILED'
      raise KaspiPay::Error.new(
        body['message'].presence || 'Kaspi Pay session refresh failed',
        code: code,
        details: body
      )
    end

    current = hook.secret_settings
    refreshed = normalize_session(body, current['phone_number'])
                .stringify_keys
                .reverse_merge(current.slice('phone_number', 'profile_id', 'organization_id', 'org_name'))
    unless refreshed['token_sn'].present? && refreshed['vtoken_secret'].present?
      raise KaspiPay::Error.new(
        'Kaspi Pay session refresh returned incomplete credentials',
        code: 'SESSION_REFRESH_INVALID',
        details: body.except('vtokenSecret', 'vtoken_secret')
      )
    end

    hook.update!(access_token: refreshed.to_json, status: 'enabled')
    hook
  end

  private

  attr_reader :account, :client

  def normalize_cashier_phone(phone_number)
    digits = phone_number.to_s.gsub(/\D/, '')
    return digits[1..] if digits.length == 11 && digits.start_with?('7', '8')

    digits
  end

  def provider_failure_response?(body)
    body['StatusCode'].to_i != 0 || body['statusCode'].to_i != 0
  end

  def normalize_session(body, phone_number)
    {
      token_sn: body['tokenSN'] || body['token_sn'],
      vtoken_secret: body['vtokenSecret'] || body['vtoken_secret'],
      profile_id: body['profileId'] || body['profile_id'],
      organization_id: body['organizationId'] || body['organization_id'],
      org_name: body['orgName'] || body['org_name'],
      phone_number: body['phone'] || body['phoneNumber'] || phone_number
    }.compact
  end
end
