# frozen_string_literal: true

class Internal::Voice::Ai::JanusSipProfilesController < Internal::Voice::Ai::BaseController
  def index
    response.headers['Cache-Control'] = 'no-store'
    render json: Telephony::AiVoice::JanusSipProfileConfigService.new.perform
  end
end
