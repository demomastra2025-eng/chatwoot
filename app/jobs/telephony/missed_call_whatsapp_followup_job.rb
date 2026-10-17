# frozen_string_literal: true

class Telephony::MissedCallWhatsappFollowupJob < ApplicationJob
  queue_as :default

  def perform(call_session_id)
    call_session = Telephony::CallSession.find_by(id: call_session_id)
    return if call_session.blank?

    Telephony::MissedCallWhatsappFollowupService.new(call_session: call_session).perform
  end
end
