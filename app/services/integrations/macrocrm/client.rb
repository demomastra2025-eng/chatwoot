class Integrations::Macrocrm::Client
  class ApiError < StandardError; end

  BASE_URL = 'https://api.macroserver.kz/v2'.freeze

  def initialize(hook:)
    @hook = hook
  end

  def find_contact(phone:)
    post('/contacts/find', { phone: phone })
  end

  def find_estate_buy(contact_id:)
    post('/estateBuy/find', { contacts_id: contact_id })
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
    response = HTTParty.post(
      "#{BASE_URL}#{endpoint}",
      body: payload.to_json,
      headers: headers
    )

    parsed_response = response.parsed_response
    return parsed_response if response.success?

    raise ApiError, "MacroCRM request failed for #{endpoint}: HTTP #{response.code} #{parsed_response}"
  rescue SocketError, Net::OpenTimeout, Net::ReadTimeout, Timeout::Error => e
    raise ApiError, "MacroCRM request failed for #{endpoint}: #{e.message}"
  end

  def get(endpoint)
    response = HTTParty.get("#{BASE_URL}#{endpoint}", headers: headers.except('Content-Type'))

    parsed_response = response.parsed_response
    return parsed_response if response.success?

    raise ApiError, "MacroCRM request failed for #{endpoint}: HTTP #{response.code} #{parsed_response}"
  rescue SocketError, Net::OpenTimeout, Net::ReadTimeout, Timeout::Error => e
    raise ApiError, "MacroCRM request failed for #{endpoint}: #{e.message}"
  end

  def headers
    {
      'Authorization' => "Bearer #{hook.access_token}",
      'AppId' => hook.settings['app_id'],
      'Content-Type' => 'application/json'
    }
  end
end
