class Telephony::AiVoice::PostCallCaptainFeaturesJob < ApplicationJob
  queue_as :captain_runtime

  discard_on ActiveRecord::RecordNotFound

  def perform(call_session_id)
    call_session = Telephony::CallSession.find(call_session_id)
    Telephony::AiVoice::PostCallCaptainFeaturesService.new(call_session: call_session).perform
  end
end
