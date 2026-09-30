# Resolves the WhatsApp Business Account shared during Embedded Signup from the
# business token itself. Mobile browsers open Meta's popup as a separate tab and
# often never deliver the WA_EMBEDDED_SIGNUP session event to our page, while the
# FB.login callback (auth code) still arrives. Meta documents that the WABA the
# customer shared is listed in the token's granular_scopes target_ids.
class Whatsapp::EmbeddedSignupWabaResolver
  SCOPE_PRIORITY = %w[whatsapp_business_management whatsapp_business_messaging].freeze
  META_ID_FORMAT = /\A\d{1,32}\z/

  class ResolutionError < StandardError
    attr_reader :error_code

    def initialize(error_code, message)
      @error_code = error_code
      super(message)
    end
  end

  def initialize(access_token, api_client: nil)
    @access_token = access_token
    @api_client = api_client || Whatsapp::FacebookApiClient.new(access_token)
  end

  def perform
    waba_ids = granted_waba_ids(@api_client.debug_token(@access_token)['data'].to_h)
    raise ResolutionError.new('waba_not_found', 'Meta did not share a WhatsApp Business Account in this signup') if waba_ids.empty?

    if waba_ids.many?
      raise ResolutionError.new('waba_ambiguous',
                                'Meta shared several WhatsApp Business Accounts; restart the connection and finish it in the Meta window')
    end

    waba_ids.first
  end

  private

  # Never guess: a single, numeric target of the most specific WhatsApp scope.
  def granted_waba_ids(token_data)
    scopes = Array(token_data['granular_scopes']).grep(Hash)
    SCOPE_PRIORITY.each do |scope_name|
      ids = scopes.select { |scope| scope['scope'].to_s == scope_name }
                  .flat_map { |scope| Array(scope['target_ids']) }
                  .map(&:to_s).grep(META_ID_FORMAT).uniq
      return ids if ids.present?
    end
    []
  end
end
