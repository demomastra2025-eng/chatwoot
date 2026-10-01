# Mobile-safe Embedded Signup for Whatsapp::EmbeddedSignupService: when the browser
# delivered only the FB.login auth code (Meta's session event was lost in a mobile
# popup tab) and the request comes from a registered signup attempt, the shared WABA
# is read from the business token instead of the missing session event.
module Whatsapp::EmbeddedSignupTokenWabaResolution
  attr_reader :waba_source

  private

  def resolve_waba_from_token!(access_token)
    @waba_source = 'session_event'
    return unless @resolve_waba_from_token

    @waba_id = Whatsapp::EmbeddedSignupWabaResolver.new(access_token).perform
    @waba_source = 'token_scope'
  end

  def required_signup_parameters
    return %i[code] if @inbox_id.present?

    @resolve_waba_from_token ? %i[code] : %i[code waba_id]
  end
end
