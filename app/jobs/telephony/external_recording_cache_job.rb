require 'safe_fetch'

class Telephony::ExternalRecordingCacheJob < ApplicationJob
  queue_as :default

  retry_on SafeFetch::Error, wait: 30.seconds, attempts: 5

  def perform(call_session_id)
    call_session = Telephony::CallSession.find_by(id: call_session_id)
    return if call_session.blank?

    Telephony::ExternalRecordingCacheService.cache!(call_session: call_session)
  end
end
